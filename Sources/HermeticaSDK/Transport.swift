import Foundation

/// HTTP to the Hermetica public endpoints: the site key travels as a bearer token and as `company_id`.
final class Transport {
    static let maxRetries = 5
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    let endpoint: String
    let siteKey: String
    let session: URLSession
    let retryBase: Double

    init(baseURL: URL, siteKey: String, session: URLSession, retryBase: Double) {
        var e = baseURL.absoluteString
        while e.hasSuffix("/") { e.removeLast() }
        endpoint = e
        self.siteKey = siteKey
        self.session = session
        self.retryBase = retryBase
    }

    /// The server took it, or never will (4xx other than 429): either way do not send it again.
    static func settled(_ status: Int) -> Bool { status > 0 && status < 500 && status != 429 }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    func url(_ path: String, _ query: [(String, String?)]) -> URL? {
        let items = ([("company_id", siteKey)] + query).compactMap { k, v -> String? in
            guard let v, !v.isEmpty else { return nil }
            return "\(Self.enc(k))=\(Self.enc(v))"
        }
        return URL(string: endpoint + path + "?" + items.joined(separator: "&"))
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(siteKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// One attempt; `nil` on any failure (a missing in-app message or fence list must never break the app).
    func get(_ path: String, _ query: [(String, String?)], done: @escaping (Data?) -> Void) {
        guard let u = url(path, query) else { return done(nil) }
        session.dataTask(with: request(u)) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            done((200..<300).contains(status) ? data : nil)
        }.resume()
    }

    /// POST with retries and one Idempotency-Key for all attempts. `done` gets the last HTTP status (0 = network failure).
    func post(_ path: String, _ body: [String: Any], done: ((Int) -> Void)? = nil) {
        guard let u = url(path, []), JSONSerialization.isValidJSONObject(body),
            let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            log("dropped a request whose body is not JSON: \(path)")
            done?(400)
            return
        }
        var r = request(u)
        r.httpMethod = "POST"
        r.httpBody = data
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        attempt(r, 0, done)
    }

    private func attempt(_ r: URLRequest, _ n: Int, _ done: ((Int) -> Void)?) {
        session.dataTask(with: r) { _, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if Self.settled(status) || n + 1 >= Self.maxRetries { done?(status); return }
            let delay = self.retryBase * pow(2, Double(n)) + Double.random(in: 0..<self.retryBase)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.attempt(r, n + 1, done) }
        }.resume()
    }
}

func log(_ message: @autoclosure () -> String) {
    if Hermetica.debug { print("[hermetica]", message()) }
}
