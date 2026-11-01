import Foundation

/// Records every request and answers with `handler` (default: 202 `{}`).
final class MockURLProtocol: URLProtocol {
    struct Seen {
        let request: URLRequest
        let body: [String: Any]?
        var path: String { request.url?.path ?? "" }
        var query: [String: String] {
            Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        }
    }

    private static let lock = NSLock()
    private static var _seen: [Seen] = []
    static var handler: ((URLRequest) -> (Int, Data))?

    static var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }
    static func reset() { lock.lock(); _seen = []; handler = nil; lock.unlock() }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream before protocols see it.
        let data = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Self.lock.lock()
        Self._seen.append(Seen(request: request, body: body))
        let h = Self.handler
        Self.lock.unlock()
        let (status, payload) = h?(request) ?? (202, Data("{}".utf8))
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ s: InputStream) -> Data {
        s.open()
        defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}
