import Foundation

/// A bounded, read-only JSON request. Credential handling is restricted to one
/// configured HTTPS origin; neither request/response bodies nor headers are logged.
final class RelayAPIClient: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private var session: URLSession?
    private var bytes = Data()
    private var completion: ((Result<Data, RelayFailure>) -> Void)?
    private var initialURL: URL?
    private var bearer: String?
    private var redirectCount = 0
    private var failure: RelayFailure?
    private let protocolClasses: [AnyClass]?
    override init() { protocolClasses = nil; super.init() }
    // Tests can intercept requests without changing production transport policy.
    init(protocolClasses: [AnyClass]) { self.protocolClasses = protocolClasses; super.init() }
    func fetch(url: URL, credential: String?, completion: @escaping (Result<Data, RelayFailure>) -> Void) {
        self.completion = completion; initialURL = url; bearer = credential
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        session.dataTask(with: request).resume()
    }
    func cancel() { session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = initialURL, let url = request.url, RelayRules.sameOrigin(original, url),
              (try? RelayRules.validateURL(url.absoluteString, mode: .api)) != nil, redirectCount < 5 else {
            failure = RelayFailure("已阻止跨站或不安全重定向，请使用最终 HTTPS 用量地址。")
            completionHandler(nil); return
        }
        redirectCount += 1
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Authorization"); safe.setValue(nil, forHTTPHeaderField: "Cookie")
        if let bearer, !bearer.isEmpty { safe.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        completionHandler(safe)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else { failure = RelayFailure("无法读取用量响应。"); completionHandler(.cancel); return }
        guard (200...299).contains(http.statusCode) else {
            failure = RelayFailure([401, 403].contains(http.statusCode) ? "访问凭据已失效或权限不足，请重新设置。" : "用量服务返回错误，请稍后重试。")
            completionHandler(.cancel); return
        }
        let mime = (http.mimeType ?? "").lowercased()
        guard mime == "application/json" || mime.hasSuffix("+json") else {
            failure = RelayFailure("用量地址返回的不是 JSON；可能需要重新登录或更换地址。")
            completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= RelayRules.maxBody else { failure = RelayFailure("用量响应超过 2 MiB 限制。"); completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard bytes.count + data.count <= RelayRules.maxBody else { failure = RelayFailure("用量响应超过 2 MiB 限制。"); dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = completion; completion = nil; bearer = nil
        let result: Result<Data, RelayFailure>
        if let failure { result = .failure(failure) }
        else if error != nil { result = .failure(RelayFailure("用量请求未成功或已超时，请检查网络和设置。")) }
        else { result = .success(bytes) }
        bytes.removeAll(keepingCapacity: false)
        session.finishTasksAndInvalidate(); self.session = nil
        DispatchQueue.main.async { callback?(result) }
    }
}
