import Foundation

// URLProtocol fixtures intercept every test URL: no external site or account is used.
private final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        let path = url.path
        if path == "/cross-origin" || path == "/same-origin" {
            let target = URL(string: path == "/cross-origin" ? "https://foreign.invalid/good" : "https://fixture.invalid/good")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status = path == "/unauthorized" ? 401 : 200
        let mime = path == "/html" ? "text/html" : "application/json"
        let size = path == "/oversized" ? String(RelayRules.maxBody + 1) : "2"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": size])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private enum APIClientTests {
    static func run(_ path: String, succeeds: Bool, expectedRequests: Int) {
        FixtureProtocol.lock.lock(); FixtureProtocol.requests.removeAll(); FixtureProtocol.lock.unlock()
        let client = RelayAPIClient(protocolClasses: [FixtureProtocol.self])
        var outcome: Result<Data, RelayFailure>?
        client.fetch(url: URL(string: "https://fixture.invalid/" + path)!, credential: "fixture-only") { outcome = $0 }
        let deadline = Date().addingTimeInterval(5)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let outcome else { fatalError("Fixture request did not finish: " + path) }
        switch outcome {
        case .success(let body): precondition(succeeds && body == Data("{}".utf8), "Unexpected success: " + path)
        case .failure(let failure):
            precondition(!succeeds, "Unexpected failure: " + path)
            precondition(!failure.message.contains("fixture-only"), "Credential appeared in an error")
        }
        FixtureProtocol.lock.lock(); let sent = FixtureProtocol.requests; FixtureProtocol.lock.unlock()
        precondition(sent.count == expectedRequests, "Unexpected request count: " + path)
        for request in sent {
            precondition(request.url?.host == "fixture.invalid", "Cross-origin request was sent")
            precondition(request.httpMethod == "GET", "Request must remain read-only")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
    }
    static func main() {
        run("good", succeeds: true, expectedRequests: 1)
        run("unauthorized", succeeds: false, expectedRequests: 1)
        run("html", succeeds: false, expectedRequests: 1)
        run("oversized", succeeds: false, expectedRequests: 1)
        run("cross-origin", succeeds: false, expectedRequests: 1)
        run("same-origin", succeeds: true, expectedRequests: 2)
        print("Relay API client: 6 isolated request fixtures passed")
    }
}
