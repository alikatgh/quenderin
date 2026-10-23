import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor public protocol RemoteHarnessClientHTTP: AnyObject {
    func request(origin: String, path: String, method: String, bearer: String?, body: RemoteHarnessJSON?) async throws -> RemoteHarnessJSON
}

/// One bounded, ephemeral session per call. No redirects, cookies, stored
/// credentials, cache or application retry/fallback, including on mutations.
@MainActor public final class RemoteHarnessClientURLSessionHTTP: RemoteHarnessClientHTTP {
    public init() {}
    public func request(origin: String, path: String, method: String = "GET", bearer: String? = nil, body: RemoteHarnessJSON? = nil) async throws -> RemoteHarnessJSON {
        let canonical = try NativeConnectionOrigin.canonical(origin)
        guard path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("#"), ["GET", "POST", "DELETE"].contains(method),
              let url = URL(string: canonical + path), (body?.data.count ?? 0) <= 65_536 else { throw RemoteHarnessClientFailure.protocolMismatch }
        let events = AsyncThrowingStream<DeepSeekHTTPEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let delegate = RemoteHarnessClientHTTPDelegate(url: url, continuation: events.continuation)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body.data }
        let task = session.dataTask(with: request)
        events.continuation.onTermination = { @Sendable _ in task.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); task.resume()
            var result = Data(); var status: Int?
            for try await event in events.stream {
                switch event {
                case .response(let code, _, let type):
                    guard status == nil, type.lowercased().hasPrefix("application/json") else { throw RemoteHarnessClientFailure.protocolMismatch }; status = code
                case .bytes(let bytes):
                    guard status != nil, result.count + bytes.count <= 1_048_576 else { throw RemoteHarnessClientFailure.limit }; result.append(bytes)
                }
            }
            guard let status, (200...299).contains(status) else { throw status == 401 || status == 403 ? RemoteHarnessClientFailure.authorization : RemoteHarnessClientFailure.connection }
            return try RemoteHarnessJSON(data: result)
        } onCancel: { task.cancel() }
    }
    nonisolated static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15; config.httpMaximumConnectionsPerHost = 1
        return config
    }
}

/// Mutable response accounting belongs exclusively to its serial delegate queue.
private final class RemoteHarnessClientHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    let continuation: AsyncThrowingStream<DeepSeekHTTPEvent, Error>.Continuation
    private var count = 0
    init(url: URL, continuation: AsyncThrowingStream<DeepSeekHTTPEvent, Error>.Continuation) { self.url = url; self.continuation = continuation }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); continuation.finish(throwing: RemoteHarnessClientFailure.protocolMismatch); task.cancel()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == url, response.expectedContentLength <= 1_048_576 else {
            continuation.finish(throwing: RemoteHarnessClientFailure.limit); completionHandler(.cancel); return
        }
        emit(.response(status: response.statusCode, url: url, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? ""), task: dataTask); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        count += data.count; guard count <= 1_048_576 else { continuation.finish(throwing: RemoteHarnessClientFailure.limit); dataTask.cancel(); return }; emit(.bytes(data), task: dataTask)
    }
    private func emit(_ value: DeepSeekHTTPEvent, task: URLSessionTask) {
        if case .dropped = continuation.yield(value) { continuation.finish(throwing: RemoteHarnessClientFailure.limit); task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: (error as NSError).code == NSURLErrorTimedOut ? RemoteHarnessClientFailure.timeout : RemoteHarnessClientFailure.connection) }
        else { continuation.finish() }
    }
}

@MainActor public protocol RemoteHarnessClientSocket: AnyObject {
    func start(origin: String) throws
    func receive() async throws -> Data
    /// Returns when accepted by the local bounded queue, not delivered.
    func enqueue(_ data: Data, failed: @escaping @MainActor () -> Void) throws
    func close()
}

@MainActor public final class RemoteHarnessClientWebSocket: RemoteHarnessClientSocket {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var queue: [Data] = []
    private var bytes = 0
    private var sends = 0
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    public init() {}
    public func start(origin: String) throws {
        guard socket == nil, let url = URL(string: "wss://" + String(try NativeConnectionOrigin.canonical(origin).dropFirst(8)) + "/ws/v1/connect") else { throw RemoteHarnessClientFailure.connection }
        let delegate = RemoteHarnessClientSocketDelegate()
        let session = URLSession(configuration: RemoteHarnessClientURLSessionHTTP.configuration(), delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url); socket.maximumMessageSize = 1_048_576
        self.session = session; self.socket = socket; socket.resume()
    }
    public func receive() async throws -> Data {
        guard let current = socket else { throw RemoteHarnessClientFailure.connection }
        let message = try await current.receive()
        guard socket === current else { throw RemoteHarnessClientFailure.connection }
        let bytes: Data
        switch message { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: throw RemoteHarnessClientFailure.protocolMismatch }
        guard bytes.count <= 1_048_576 else { throw RemoteHarnessClientFailure.limit }; return bytes
    }
    public func enqueue(_ data: Data, failed: @escaping @MainActor () -> Void) throws {
        guard let current = socket, data.count <= 1_048_576, sends < 256, data.count <= 8_388_608 - bytes else { throw RemoteHarnessClientFailure.limit }
        queue.append(data); bytes += data.count; sends += 1
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                while !self.queue.isEmpty, self.socket === current {
                    let data = self.queue.removeFirst()
                    self.deadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                        guard let self, self.socket === current else { return }; self.close(); failed()
                    }
                    try await current.send(.data(data))
                    self.deadline?.cancel(); self.deadline = nil
                    guard self.socket === current else { return }
                    self.bytes -= data.count; self.sends -= 1
                }
                self.work = nil
            } catch {
                guard self.socket === current else { return }; self.close(); failed()
            }
        }
    }
    public func close() {
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil; deadline?.cancel(); deadline = nil; work?.cancel(); work = nil
        queue.removeAll(); bytes = 0; sends = 0
    }
}
private final class RemoteHarnessClientSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil); task.cancel() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
