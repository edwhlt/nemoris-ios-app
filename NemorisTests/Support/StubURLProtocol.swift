import Foundation

/// Interception des requêtes réseau pour les tests.
///
/// Enregistré globalement, ce `URLProtocol` court-circuite `URLSession.shared`
/// avant que la requête ne parte — les clients d'API n'ont donc AUCUNE
/// modification à subir pour devenir testables. C'est la différence avec
/// l'injection de repository : là il fallait toucher le code, ici non.
///
/// ⚠️ L'enregistrement est un état GLOBAL du processus. Toute suite qui
/// l'utilise doit être marquée `.serialized`, sinon deux tests parallèles se
/// disputent la table des réponses et se répondent mutuellement.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    /// Réponse à servir pour une requête donnée.
    struct Stub {
        let statusCode: Int
        let body: Data
        /// Erreur réseau à lever au lieu de répondre — pour éprouver les
        /// chemins d'échec, qui sont la moitié de l'intérêt d'un client d'API.
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

    // MARK: - Table des réponses

    private static let lock = NSLock()
    /// Prédicat sur l'URL → réponse. Le premier qui matche gagne.
    nonisolated(unsafe) private static var stubs: [(match: (URL) -> Bool, stub: Stub)] = []
    /// URLs réellement demandées, dans l'ordre — permet de vérifier qu'un client
    /// a bien appelé ce qu'il devait, et pas autre chose.
    nonisolated(unsafe) private static var requested: [URL] = []

    /// Arme l'interception et vide la table. À appeler au début de chaque test.
    static func start() {
        lock.lock(); stubs = []; requested = []; lock.unlock()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    /// Désarme. À appeler en `defer`, sinon l'interception fuit sur les tests
    /// suivants et les fait échouer de façon incompréhensible.
    static func stop() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        lock.lock(); stubs = []; requested = []; lock.unlock()
    }

    /// Sert `stub` à toute URL dont le texte contient `fragment`.
    static func on(_ fragment: String, _ stub: Stub) {
        lock.lock()
        stubs.append((match: { $0.absoluteString.contains(fragment) }, stub: stub))
        lock.unlock()
    }

    /// Sert `stub` à toute requête non déjà couverte.
    static func onAny(_ stub: Stub) {
        lock.lock()
        stubs.append((match: { _ in true }, stub: stub))
        lock.unlock()
    }

    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    private static func stub(for url: URL) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        requested.append(url)
        return stubs.first { $0.match(url) }?.stub
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let stub = Self.stub(for: url) else {
            // Aucune réponse prévue : on échoue explicitement plutôt que de
            // laisser la requête partir sur le vrai réseau. Un test qui appelle
            // une URL non prévue doit le savoir.
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
