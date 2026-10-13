import SwiftUI

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1024 * 1024 // 100MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    func clear() {
        cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }
}

public struct CachedAsyncImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    public init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        if let url, let cached = ImageCache.shared.image(for: url) {
            _image = State(initialValue: cached)
        }
    }

    public var body: some View {
        ZStack {
            if let image {
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
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            self.image = cached
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
                  let downloaded = UIImage(data: data) else {
                return
            }

            ImageCache.shared.insert(downloaded, for: url)
            self.image = downloaded
        } catch {
            // Ignore cancellation or transient network error
        }
    }
}
