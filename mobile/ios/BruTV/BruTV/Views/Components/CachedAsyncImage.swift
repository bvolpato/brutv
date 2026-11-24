import SwiftUI
import ImageIO
import UIKit

/// Limits concurrent ImageIO decodes so fast scrolling through thousands of cards cannot spike RAM.
private actor ImageDecodeLimiter {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    func run<T: Sendable>(_ work: @Sendable () -> T) async -> T {
        await acquire()
        defer { release() }
        return work()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024
        )
        return URLSession(configuration: config)
    }()

    private static let negativeTTL: TimeInterval = 300
    private static let maxNegativeEntries = 1000
    private static let decodeLimiter = ImageDecodeLimiter(limit: 4)

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failedURLs: [URL: TimeInterval] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        #if os(tvOS)
        cache.countLimit = 250
        cache.totalCostLimit = 48 * 1024 * 1024 // 48MB on Apple TV
        #else
        cache.countLimit = 400
        cache.totalCostLimit = 72 * 1024 * 1024 // 72MB
        #endif
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeMemory()
            }
        }
    }

    private static func bucketedPixelSize(_ size: CGFloat) -> Int {
        let clamped = max(64, min(1024, Int(size.rounded())))
        if clamped <= 128 { return 128 }
        if clamped <= 256 { return 256 }
        if clamped <= 384 { return 384 }
        if clamped <= 512 { return 512 }
        return 768
    }

    private static func cacheKey(url: URL, pixelSize: Int) -> String {
        "\(pixelSize):\(url.absoluteString)"
    }

    func image(for url: URL, targetPixelSize: CGFloat = 256) -> UIImage? {
        let bucket = Self.bucketedPixelSize(targetPixelSize)
        return cache.object(forKey: Self.cacheKey(url: url, pixelSize: bucket) as NSString)
    }

    func isNegativelyCached(_ url: URL) -> Bool {
        guard let failedAt = failedURLs[url] else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - failedAt < Self.negativeTTL {
            return true
        }
        failedURLs.removeValue(forKey: url)
        return false
    }

    private func recordFailure(for url: URL) {
        if failedURLs.count >= Self.maxNegativeEntries {
            failedURLs.removeAll(keepingCapacity: true)
        }
        failedURLs[url] = ProcessInfo.processInfo.systemUptime
    }

    func insert(_ image: UIImage, for url: URL, targetPixelSize: CGFloat = 256) {
        let bucket = Self.bucketedPixelSize(targetPixelSize)
        let cost: Int
        if let cgImage = image.cgImage {
            cost = cgImage.bytesPerRow * cgImage.height
        } else {
            cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        cache.setObject(image, forKey: Self.cacheKey(url: url, pixelSize: bucket) as NSString, cost: max(1, cost))
        failedURLs.removeValue(forKey: url)
    }

    func load(url: URL, targetPixelSize: CGFloat = 256) async -> UIImage? {
        let bucket = Self.bucketedPixelSize(targetPixelSize)
        let key = Self.cacheKey(url: url, pixelSize: bucket)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if isNegativelyCached(url) {
            return nil
        }

        let task: Task<UIImage?, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let newTask = Task<UIImage?, Never> { [weak self] in
                defer {
                    Task { @MainActor [weak self] in
                        self?.inFlight.removeValue(forKey: key)
                    }
                }
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 8
                    request.cachePolicy = .returnCacheDataElseLoad
                    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
                    request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

                    let (data, response) = try await Self.session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode),
                          !data.isEmpty else {
                        await MainActor.run { self?.recordFailure(for: url) }
                        return nil
                    }

                    let maxPx = CGFloat(bucket)
                    let decoded = await Self.decodeLimiter.run {
                        Self.decodeDownsampledImage(from: data, maxPixelSize: maxPx)
                    }
                    guard let decoded else {
                        await MainActor.run { self?.recordFailure(for: url) }
                        return nil
                    }
                    await MainActor.run {
                        self?.insert(decoded, for: url, targetPixelSize: maxPx)
                    }
                    return decoded
                } catch {
                    if !(error is CancellationError) {
                        await MainActor.run { self?.recordFailure(for: url) }
                    }
                    return nil
                }
            }
            inFlight[key] = newTask
            task = newTask
        }

        return await task.value
    }

    func purgeMemory() {
        cache.removeAllObjects()
    }

    func clear() {
        cache.removeAllObjects()
        failedURLs.removeAll()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        Self.session.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
    }

    private nonisolated static func decodeDownsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data)
    }
}

public struct CachedAsyncImage<Placeholder: View>: View {
    private let url: URL?
    private let targetPixelSize: CGFloat
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    public init(
        url: URL?,
        targetPixelSize: CGFloat = 256,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetPixelSize = targetPixelSize
        self.placeholder = placeholder
        if let url, let cached = ImageCache.shared.image(for: url, targetPixelSize: targetPixelSize) {
            _image = State(initialValue: cached)
            _loadedURL = State(initialValue: url)
        }
    }

    public var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else {
            self.image = nil
            self.loadedURL = nil
            return
        }

        if let cached = ImageCache.shared.image(for: url, targetPixelSize: targetPixelSize) {
            self.image = cached
            self.loadedURL = url
            return
        }

        // Clear stale artwork immediately on URL change so reused cells never flash the previous item.
        if loadedURL != url {
            self.image = nil
            self.loadedURL = nil
        }

        let decoded = await ImageCache.shared.load(url: url, targetPixelSize: targetPixelSize)
        guard !Task.isCancelled else { return }
        if let decoded {
            self.image = decoded
            self.loadedURL = url
        }
    }
}
