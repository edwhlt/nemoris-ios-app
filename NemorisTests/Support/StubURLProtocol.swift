import Foundation

/// Intercepting network requests for tests.
///
/// Registered globally, this `URLProtocol` short-circuits `URLSession.shared`
/// before the request leaves — so API clients need NO
/// modification at all to become testable. That's the difference from
/// repository injection: there the code had to be touched, here it doesn't.
///
/// ⚠️ Registration is process-GLOBAL state. Any suite that
/// uses it must be marked `.serialized`, otherwise two parallel tests will
/// fight over the response table and answer each other's requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    /// The response to serve for a given request.
    struct Stub {
        let statusCode: Int
        let body: Data
        /// A network error to throw instead of responding — to exercise
        /// failure paths, which are half the point of testing an API client.
        let failure: Error?

        init(statusCode: Int = 200, body: Data = Data(), failure: Error? = nil) {
            self.statusCode = statusCode
            self.body = body
            self.failure = failure
        }

        static func json(_ text: String, statusCode: Int = 200) -> Stub {
            Stub(statusCode: statusCode, body: Data(text.utf8))
        }

        static func status(_ code: Int) -> Stub { Stub(statusCode: code) }

        static func networkFailure() -> Stub {
            Stub(failure: URLError(.notConnectedToInternet))
        }
    }

    // MARK: - Response table

    /// The request as it actually went out — this lets you verify
    /// not just WHERE a client calls, but HOW it identifies itself.
    struct Capture {
        let url: URL
        let headers: [String: String]
        let body: Data?

        var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        func header(_ nom: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(nom) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    /// A predicate on the URL → response. The first match wins.
    nonisolated(unsafe) private static var stubs: [(match: (URL) -> Bool, stub: Stub)] = []
    /// Requests actually emitted, in order.
    nonisolated(unsafe) private static var captures: [Capture] = []

    /// Arms interception and clears the table. Call at the start of each test.
    static func start() {
        lock.lock(); stubs = []; captures = []; lock.unlock()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    /// Disarms it. Call it in a `defer`, otherwise interception leaks into the
    /// following tests and makes them fail incomprehensibly.
    static func stop() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        lock.lock(); stubs = []; captures = []; lock.unlock()
    }

    /// Serves `stub` to any URL whose text contains `fragment`.
    static func on(_ fragment: String, _ stub: Stub) {
        lock.lock()
        stubs.append((match: { $0.absoluteString.contains(fragment) }, stub: stub))
        lock.unlock()
    }

    /// Serves `stub` to any request not already covered.
    static func onAny(_ stub: Stub) {
        lock.lock()
        stubs.append((match: { _ in true }, stub: stub))
        lock.unlock()
    }

    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return captures.map(\.url)
    }

    /// Requests emitted, with their headers and body.
    static var requests: [Capture] {
        lock.lock(); defer { lock.unlock() }
        return captures
    }

    private static func stub(for requete: URLRequest, url: URL) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        captures.append(Capture(url: url,
                                headers: requete.allHTTPHeaderFields ?? [:],
                                body: corps(de: requete)))
        return stubs.first { $0.match(url) }?.stub
    }

    /// ⚠️ `URLProtocol` receives the body as a STREAM, not `Data`:
    /// `httpBody` is almost always `nil` here, even when the caller set it.
    /// Without reading this stream, any check on the
    /// body would miss it and test nothing.
    private static func corps(de requete: URLRequest) -> Data? {
        if let direct = requete.httpBody { return direct }
        guard let flux = requete.httpBodyStream else { return nil }
        flux.open()
        defer { flux.close() }
        var accumulateur = Data()
        var tampon = [UInt8](repeating: 0, count: 4096)
        while flux.hasBytesAvailable {
            let lus = flux.read(&tampon, maxLength: tampon.count)
            if lus <= 0 { break }
            accumulateur.append(contentsOf: tampon[0..<lus])
        }
        return accumulateur.isEmpty ? nil : accumulateur
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let stub = Self.stub(for: request, url: url) else {
            // No response planned: fail explicitly rather than
            // letting the request go out over the real network. A test that calls
            // an unplanned URL needs to know about it.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
