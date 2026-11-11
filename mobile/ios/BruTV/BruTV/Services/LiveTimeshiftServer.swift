#if canImport(Network)
import Foundation
import Network

/// AVPlayer requires ordinary HTTP URLs for HLS media segments, including local recordings.
final class LiveTimeshiftServer: @unchecked Sendable {
    private let recorder: LiveTimeshiftRecorder
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "com.bvolpato.brutv.live-http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handles: [ObjectIdentifier: (FileHandle, String)] = [:]
    private var startContinuation: CheckedContinuation<URL, Error>?

    init(recorder: LiveTimeshiftRecorder) { self.recorder = recorder }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    self.startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/live.m3u8") else { return }
                            self.finishStart(.success(url))
                        case .failed(let error): self.finishStart(.failure(error))
                        case .cancelled: self.finishStart(.failure(CancellationError()))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, self.connections.count < 4 else { connection.cancel(); return }
                        let identifier = ObjectIdentifier(connection)
                        self.connections[identifier] = connection
                        connection.stateUpdateHandler = { [weak self] state in
                            switch state {
                            case .failed, .cancelled:
                                self?.connections.removeValue(forKey: identifier)
                                self?.closeFile(identifier)
                            default: break
                            }
                        }
                        connection.start(queue: self.queue)
                        self.receive(connection, bytes: Data())
                        self.queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
                            guard let connection else { return }
                            self?.connections.removeValue(forKey: identifier)
                            self?.closeFile(identifier)
                            connection.cancel()
                        }
                    }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    func stop() {
        queue.async {
            self.finishStart(.failure(CancellationError()))
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            for identifier in Array(self.handles.keys) { self.closeFile(identifier) }
        }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = bytes
            if let data { request.append(data) }
            guard request.count <= 16 * 1024 else {
                self.send(connection, status: 431, body: Data(), head: false)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: request)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, bytes: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else {
            send(connection, status: 400, body: Data(), head: false); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else {
            send(connection, status: 405, body: Data(), head: false); return
        }
        let head = first[0] == "HEAD"
        guard let path = String(first[1]).split(separator: "?", maxSplits: 1).first else {
            send(connection, status: 400, body: Data(), head: head); return
        }
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { send(connection, status: 404, body: Data(), head: head); return }
        let name = String(path.dropFirst(prefix.count))
        guard name == "live.m3u8" || (name.hasPrefix("segment-") && name.hasSuffix(".ts") &&
            name.dropFirst(8).dropLast(3).allSatisfy(\.isNumber)) else {
            send(connection, status: 404, body: Data(), head: head); return
        }
        let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }).map {
            String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
        }
        Task {
            do {
                if name == "live.m3u8" {
                    let data = try await recorder.playlist()
                    self.queue.async {
                        self.send(connection, status: 200, body: data, head: head, type: "application/vnd.apple.mpegurl")
                    }
                } else {
                    guard let (handle, length) = try await recorder.openSegment(named: name) else {
                        self.queue.async { self.send(connection, status: 410, body: Data(), head: head) }
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
                                          extra: "Content-Range: bytes */\(length)\r\n")
                                return
                            }
                            range = requested
                        } else { range = 0..<length }
                        self.handles[identifier] = (handle, name)
                        do { try handle.seek(toOffset: UInt64(range.lowerBound)) }
                        catch { self.closeFile(identifier); connection.cancel(); return }
                        let extra = rangeHeader == nil ? "" : "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)\r\n"
                        let header = Self.header(status: rangeHeader == nil ? 200 : 206, type: "video/mp2t",
                                                 length: range.count, extra: extra)
                        connection.send(content: header, completion: .contentProcessed { error in
                            if error != nil || head {
                                self.closeFile(identifier); connection.cancel(); return
                            }
                            self.sendFile(connection, remaining: range.count)
                        })
                    }
                }
            } catch {
                self.queue.async { self.send(connection, status: 503, body: Data(), head: head) }
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

    private static func header(status: Int, type: String, length: Int, extra: String) -> Data {
        let reasons = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                       405: "Method Not Allowed", 410: "Gone", 416: "Range Not Satisfiable",
                       431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        return Data("HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n".utf8)
    }

    private func closeFile(_ identifier: ObjectIdentifier) {
        if let (handle, name) = handles.removeValue(forKey: identifier) { release(handle, named: name) }
    }

    private func release(_ handle: FileHandle, named name: String) {
        try? handle.close()
        Task { await recorder.releaseSegment(named: name) }
    }

    private func sendFile(_ connection: NWConnection, remaining: Int) {
        let identifier = ObjectIdentifier(connection)
        guard remaining > 0, let (handle, _) = handles[identifier] else {
            closeFile(identifier); connection.cancel(); return
        }
        do {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else {
                closeFile(identifier); connection.cancel(); return
            }
            connection.send(content: chunk, isComplete: chunk.count == remaining,
                            completion: .contentProcessed { error in
                if error != nil { self.closeFile(identifier); connection.cancel(); return }
                self.sendFile(connection, remaining: remaining - chunk.count)
            })
        } catch { closeFile(identifier); connection.cancel() }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data, head: Bool,
                      type: String = "application/octet-stream", extra: String = "") {
        connection.send(content: Self.header(status: status, type: type, length: body.count, extra: extra),
                        completion: .contentProcessed { error in
            if error != nil || head || body.isEmpty { connection.cancel(); return }
            connection.send(content: body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        })
    }
}
#endif
