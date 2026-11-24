#if canImport(Network)
import Foundation
import Network

/// AVPlayer requires ordinary HTTP URLs for HLS media segments, including local recordings.
/// Supports HTTP/1.1 persistent keep-alive connections so AVPlayer reuses TCP sockets across
/// playlist polls and segment fetches without per-request handshake or close-grace overhead.
final class LiveTimeshiftServer: @unchecked Sendable {
    private static let maxConnections = 32
    private static let idleTimeoutSeconds: TimeInterval = 15
    private static let closeGraceSeconds: TimeInterval = 2
    private static let startTimeoutSeconds: TimeInterval = 5
    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    private let recorder: LiveTimeshiftRecorder
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "com.bvolpato.brutv.live-http")
    private let stateLock = NSLock()
    private var _isRunning = false
    private var onFailure: (@Sendable () -> Void)?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var idleTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var handles: [ObjectIdentifier: (FileHandle, String)] = [:]
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var started = false
    private var stopped = false

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    init(recorder: LiveTimeshiftRecorder, onFailure: (@Sendable () -> Void)? = nil) {
        self.recorder = recorder
        self.onFailure = onFailure
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    self.startContinuation = continuation

                    let startTimeout = DispatchWorkItem { [weak self] in
                        guard let self, self.startContinuation != nil else { return }
                        self.listener?.cancel()
                        self.finishStart(.failure(LiveTimeshiftError.startupTimeout))
                    }
                    self.startTimeoutWorkItem = startTimeout
                    self.queue.asyncAfter(deadline: .now() + Self.startTimeoutSeconds, execute: startTimeout)

                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/live.m3u8") else { return }
                            self.started = true
                            self.setRunning(true)
                            self.finishStart(.success(url))
                        case .waiting:
                            // Allow brief transient local interface wait; startTimeout bounds startup.
                            break
                        case .failed(let error):
                            let wasRunning = self.started && !self.stopped
                            self.started = false
                            self.setRunning(false)
                            if self.startContinuation != nil {
                                self.finishStart(.failure(error))
                            } else if wasRunning {
                                self.notifyFailure()
                            }
                        case .cancelled:
                            let wasRunning = self.started && !self.stopped
                            self.started = false
                            self.setRunning(false)
                            if self.startContinuation != nil {
                                self.finishStart(.failure(CancellationError()))
                            } else if wasRunning {
                                self.notifyFailure()
                            }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, !self.stopped, self.connections.count < Self.maxConnections else {
                            connection.cancel()
                            return
                        }
                        let identifier = ObjectIdentifier(connection)
                        self.connections[identifier] = connection
                        connection.stateUpdateHandler = { [weak self] state in
                            switch state {
                            case .failed, .cancelled:
                                self?.cleanupConnection(identifier)
                            default:
                                break
                            }
                        }
                        connection.start(queue: self.queue)
                        self.scheduleIdleTimeout(for: connection, seconds: Self.idleTimeoutSeconds)
                        self.receive(connection, bytes: Data())
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        _isRunning = value
        stateLock.unlock()
    }

    private func notifyFailure() {
        let callback = onFailure
        onFailure = nil
        callback?()
    }

    private func finishStart(_ result: Result<URL, Error>) {
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    func stop() {
        setRunning(false)
        queue.async {
            self.stopped = true
            self.started = false
            self.onFailure = nil
            self.finishStart(.failure(CancellationError()))
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for timer in self.idleTimers.values { timer.cancel() }
            self.idleTimers.removeAll()
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            for identifier in Array(self.handles.keys) { self.closeFile(identifier) }
        }
    }

    private func scheduleIdleTimeout(for connection: NWConnection, seconds: TimeInterval) {
        let identifier = ObjectIdentifier(connection)
        idleTimers[identifier]?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self else { return }
            self.idleTimers.removeValue(forKey: identifier)
            guard let connection else {
                self.cleanupConnection(identifier)
                return
            }
            self.teardownConnection(connection)
        }
        idleTimers[identifier] = workItem
        queue.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func cleanupConnection(_ identifier: ObjectIdentifier) {
        idleTimers.removeValue(forKey: identifier)?.cancel()
        connections.removeValue(forKey: identifier)
        closeFile(identifier)
    }

    private func teardownConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        cleanupConnection(identifier)
        connection.cancel()
    }

    /// Completes a response cleanly: for keep-alive connections, immediately resumes reading
    /// the next HTTP request on the same TCP socket; otherwise waits briefly for client EOF.
    private func completeResponse(_ connection: NWConnection, keepAlive: Bool, remainder: Data) {
        let identifier = ObjectIdentifier(connection)
        closeFile(identifier)
        guard !stopped, connections[identifier] != nil else { return }
        if keepAlive {
            scheduleIdleTimeout(for: connection, seconds: Self.idleTimeoutSeconds)
            if !remainder.isEmpty, let delimiterRange = remainder.range(of: Self.headerDelimiter) {
                let nextRequest = Data(remainder[remainder.startIndex..<delimiterRange.upperBound])
                let nextRemainder = Data(remainder[delimiterRange.upperBound...])
                respond(connection, request: nextRequest, remainder: nextRemainder)
            } else {
                receive(connection, bytes: remainder)
            }
            return
        }
        finishClosingConnection(connection)
    }

    private func finishClosingConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        closeFile(identifier)
        guard connections[identifier] != nil else { return }
        scheduleIdleTimeout(for: connection, seconds: Self.closeGraceSeconds)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.teardownConnection(connection)
            } else if self.connections[identifier] != nil {
                self.finishClosingConnection(connection)
            }
        }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = bytes
            if let data {
                buffer.append(data)
                self.scheduleIdleTimeout(for: connection, seconds: Self.idleTimeoutSeconds)
            }
            guard buffer.count <= 16 * 1024 else {
                self.send(connection, status: 431, body: Data(), head: false, keepAlive: false, remainder: Data())
                return
            }
            if let delimiterRange = buffer.range(of: Self.headerDelimiter) {
                let request = Data(buffer[buffer.startIndex..<delimiterRange.upperBound])
                let remainder = Data(buffer[delimiterRange.upperBound...])
                self.respond(connection, request: request, remainder: remainder)
            } else if complete || error != nil {
                self.teardownConnection(connection)
            } else {
                self.receive(connection, bytes: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data, remainder: Data) {
        guard let text = String(data: request, encoding: .utf8) else {
            send(connection, status: 400, body: Data(), head: false, keepAlive: false, remainder: Data()); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else {
            send(connection, status: 405, body: Data(), head: false, keepAlive: false, remainder: Data()); return
        }
        let head = first[0] == "HEAD"
        let httpVersion = first[2].uppercased()
        let connectionHeader = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("connection:") }).map {
            String($0.dropFirst("connection:".count)).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let keepAlive: Bool
        if let connectionHeader {
            if connectionHeader.contains("close") {
                keepAlive = false
            } else if connectionHeader.contains("keep-alive") {
                keepAlive = true
            } else {
                keepAlive = httpVersion == "HTTP/1.1"
            }
        } else {
            keepAlive = httpVersion == "HTTP/1.1"
        }

        guard let path = String(first[1]).split(separator: "?", maxSplits: 1).first else {
            send(connection, status: 400, body: Data(), head: head, keepAlive: false, remainder: Data()); return
        }
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else {
            send(connection, status: 404, body: Data(), head: head, keepAlive: keepAlive, remainder: remainder); return
        }
        let name = String(path.dropFirst(prefix.count))
        guard name == "live.m3u8" || (name.hasPrefix("segment-") && name.hasSuffix(".ts") &&
            name.dropFirst(8).dropLast(3).allSatisfy(\.isNumber)) else {
            send(connection, status: 404, body: Data(), head: head, keepAlive: keepAlive, remainder: remainder); return
        }
        let rangeHeader = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }).map {
            String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
        }
        Task {
            do {
                if name == "live.m3u8" {
                    let data = try await recorder.playlist()
                    self.queue.async {
                        self.send(connection, status: 200, body: data, head: head,
                                  type: "application/vnd.apple.mpegurl", keepAlive: keepAlive, remainder: remainder)
                    }
                } else {
                    guard let (handle, length) = try await recorder.openSegment(named: name) else {
                        self.queue.async {
                            self.send(connection, status: 410, body: Data(), head: head, keepAlive: keepAlive, remainder: remainder)
                        }
                        return
                    }
                    self.queue.async {
                        let identifier = ObjectIdentifier(connection)
                        guard self.connections[identifier] != nil else { self.release(handle, named: name); return }
                        let range: Range<Int>
                        if let header = rangeHeader {
                            guard let requested = Self.range(header, length: length) else {
                                self.release(handle, named: name)
                                self.send(connection, status: 416, body: Data(), head: head,
                                          extra: "Content-Range: bytes */\(length)\r\n",
                                          keepAlive: keepAlive, remainder: remainder)
                                return
                            }
                            range = requested
                        } else { range = 0..<length }
                        self.handles[identifier] = (handle, name)
                        do { try handle.seek(toOffset: UInt64(range.lowerBound)) }
                        catch { self.teardownConnection(connection); return }
                        let extra = rangeHeader == nil ? "" : "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)\r\n"
                        let header = Self.header(status: rangeHeader == nil ? 200 : 206, type: "video/mp2t",
                                                 length: range.count, extra: extra, keepAlive: keepAlive)
                        let headerOnly = head || range.isEmpty
                        let finalFrame = headerOnly && !keepAlive
                        connection.send(
                            content: header,
                            contentContext: finalFrame ? .finalMessage : .defaultMessage,
                            isComplete: finalFrame,
                            completion: .contentProcessed { error in
                                if error != nil {
                                    self.teardownConnection(connection)
                                    return
                                }
                                if headerOnly {
                                    self.completeResponse(connection, keepAlive: keepAlive, remainder: remainder)
                                    return
                                }
                                self.scheduleIdleTimeout(for: connection, seconds: Self.idleTimeoutSeconds)
                                self.sendFile(connection, remaining: range.count, keepAlive: keepAlive, remainder: remainder)
                            }
                        )
                    }
                }
            } catch {
                self.queue.async {
                    self.send(connection, status: 503, body: Data(), head: head, keepAlive: keepAlive, remainder: remainder)
                }
            }
        }
    }

    private static func range(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0, !header.contains(",") else { return nil }
        let values = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard values.count == 2 else { return nil }
        if values[0].isEmpty {
            guard let suffix = Int(values[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(values[0]), start >= 0, start < length else { return nil }
        let last = values[1].isEmpty ? length - 1 : Int(values[1])
        guard let last, last >= start else { return nil }
        return start..<(min(last, length - 1) + 1)
    }

    private static func header(status: Int, type: String, length: Int, extra: String, keepAlive: Bool) -> Data {
        let reasons = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                       405: "Method Not Allowed", 410: "Gone", 416: "Range Not Satisfiable",
                       431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        let connHeader = keepAlive
            ? "Connection: keep-alive\r\nKeep-Alive: timeout=\(Int(idleTimeoutSeconds))\r\n"
            : "Connection: close\r\n"
        return Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\n\(connHeader)\(extra)\r\n".utf8)
    }

    private func closeFile(_ identifier: ObjectIdentifier) {
        if let (handle, name) = handles.removeValue(forKey: identifier) { release(handle, named: name) }
    }

    private func release(_ handle: FileHandle, named name: String) {
        try? handle.close()
        Task { await recorder.releaseSegment(named: name) }
    }

    private func sendFile(_ connection: NWConnection, remaining: Int, keepAlive: Bool, remainder: Data) {
        let identifier = ObjectIdentifier(connection)
        guard remaining > 0, let (handle, _) = handles[identifier] else {
            completeResponse(connection, keepAlive: keepAlive, remainder: remainder)
            return
        }
        do {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else {
                completeResponse(connection, keepAlive: keepAlive, remainder: remainder)
                return
            }
            let isLastChunk = chunk.count == remaining
            let finalFrame = isLastChunk && !keepAlive
            connection.send(
                content: chunk,
                contentContext: finalFrame ? .finalMessage : .defaultMessage,
                isComplete: finalFrame,
                completion: .contentProcessed { error in
                    if error != nil {
                        self.teardownConnection(connection)
                        return
                    }
                    if isLastChunk {
                        self.completeResponse(connection, keepAlive: keepAlive, remainder: remainder)
                        return
                    }
                    self.scheduleIdleTimeout(for: connection, seconds: Self.idleTimeoutSeconds)
                    self.sendFile(connection, remaining: remaining - chunk.count, keepAlive: keepAlive, remainder: remainder)
                }
            )
        } catch {
            teardownConnection(connection)
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data, head: Bool,
                      type: String = "application/octet-stream", extra: String = "",
                      keepAlive: Bool, remainder: Data) {
        let headerOnly = head || body.isEmpty
        let headerFinal = headerOnly && !keepAlive
        connection.send(
            content: Self.header(status: status, type: type, length: body.count, extra: extra, keepAlive: keepAlive),
            contentContext: headerFinal ? .finalMessage : .defaultMessage,
            isComplete: headerFinal,
            completion: .contentProcessed { error in
                if error != nil {
                    self.teardownConnection(connection)
                    return
                }
                if headerOnly {
                    self.completeResponse(connection, keepAlive: keepAlive, remainder: remainder)
                    return
                }
                self.scheduleIdleTimeout(for: connection, seconds: Self.idleTimeoutSeconds)
                let bodyFinal = !keepAlive
                connection.send(
                    content: body,
                    contentContext: bodyFinal ? .finalMessage : .defaultMessage,
                    isComplete: bodyFinal,
                    completion: .contentProcessed { error in
                        if error != nil {
                            self.teardownConnection(connection)
                        } else {
                            self.completeResponse(connection, keepAlive: keepAlive, remainder: remainder)
                        }
                    }
                )
            }
        )
    }
}
#endif
