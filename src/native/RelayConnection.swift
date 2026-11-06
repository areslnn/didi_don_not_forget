import AppKit
import Foundation
import WebKit

/// Configurable, read-only usage provider. No configured endpoint means no
/// remote requests. Configuration IDs isolate credentials, caches and callbacks.
@MainActor
final class RelayConnection: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onSnapshot: ((RelaySnapshot) -> Void)?
    private(set) var configuration: RelayConfiguration?
    private var started = false
    private var generation = 0
    private var refreshTimer: Timer?
    private var retryTimer: Timer?
    private var api: RelayAPIClient?
    private var browser: WKWebView?
    private var loginWindow: NSWindow?
    private var popupWindows: [NSWindow] = []
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var settings: RelaySettings?
    private var lastSnapshot: RelaySnapshot?
    private var readerSource: String?
    private var evaluating = false
    private var documentCommitted = false
    private var readDeadline = Date.distantPast
    private var earliestAcceptance = Date.distantPast
    private var candidate: Data?
    private var candidateSince = Date.distantPast
    private var lastIssue = "等待配置"
    private struct Diagnostic: Codable { let connectionID: String; let phase: String; let reason: String; let updatedAt: Date }

    func start() {
        guard !started else { return }; started = true
        if let value = RelayStore.read(RelayConfiguration.self, from: "relay-config.json"), (try? RelayRules.validate(value)) != nil { configuration = value }
        guard configuration != nil else { emitUnconfigured(); return }
        loadCache(); startConfigured()
    }
    func showSettings() {
        if !started { start() }
        if settings == nil {
            let form = RelaySettings()
            form.onSave = { [weak self] value, credential, clear in try self?.saveConfiguration(value, credential: credential, clearCredential: clear) }
            settings = form
        }
        settings?.show(configuration)
    }
    func showLogin() {
        guard let config = configuration else { showSettings(); return }
        guard config.mode == .web else { showSettings(); return }
        if browser == nil { makeBrowser(config) }
        NSApp.activate(ignoringOtherApps: true); loginWindow?.makeKeyAndOrderFront(nil)
        if browser?.url == nil { openConfiguredPage() }
    }
    func refresh() {
        guard started, let config = configuration else { return }
        if config.mode == .api { requestAPI(config); return }
        if browser == nil { makeBrowser(config) }
        if loginWindow?.isVisible == true, !isUsagePage(browser?.url) { return }
        if isUsagePage(browser?.url) { browser?.reload() } else { openConfiguredPage() }
    }
    func stop() {
        started = false; cancelConnection(); settings?.close()
    }
    private func cancelConnection() {
        generation += 1
        refreshTimer?.invalidate(); refreshTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        api?.cancel(); api = nil
        urlObservation?.invalidate(); urlObservation = nil
        loadingObservation?.invalidate(); loadingObservation = nil
        browser?.navigationDelegate = nil; browser?.uiDelegate = nil; browser?.stopLoading()
        for window in popupWindows { (window.contentView as? WKWebView)?.stopLoading(); window.close() }
        popupWindows.removeAll(); loginWindow?.close(); loginWindow = nil; browser = nil
        evaluating = false; documentCommitted = false; candidate = nil
    }
    private func saveConfiguration(_ value: RelayConfiguration, credential: String?, clearCredential: Bool) throws {
        let url = try RelayRules.validate(value)
        let old = configuration
        var secret = credential
        if value.mode == .api, !clearCredential, secret == nil, let old, old.mode == .api,
           let oldURL = try? RelayRules.validate(old), RelayRules.sameOrigin(oldURL, url) {
            secret = try RelayKeychain.read(old.connectionID)
        }
        if clearCredential || value.mode == .web { secret = nil }
        try RelayKeychain.save(secret, id: value.connectionID)
        do { try RelayStore.write(value, to: "relay-config.json") }
        catch { RelayKeychain.remove(value.connectionID); throw RelayFailure("配置未能保存，现有连接未改变。") }
        cancelConnection()
        configuration = value; lastSnapshot = nil; RelayStore.clearReadings()
        if let old { RelayKeychain.remove(old.connectionID) }
        issue("设置已更新，等待新的用量数据", phase: "loading")
        startConfigured()
        if value.mode == .web { showLogin() }
    }
    private func startConfigured() {
        guard started, let config = configuration else { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        if config.mode == .web {
            readerSource = Bundle.main.url(forResource: "RelayReader", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            makeBrowser(config)
        }
        refresh()
    }
    private func emitUnconfigured() {
        onSnapshot?(RelaySnapshot(connectionID: "", periodLabel: "统计周期未配置", capturedAt: nil, sourceLabel: "中转站", status: "unconfigured", entries: []))
    }
    private func requestAPI(_ config: RelayConfiguration) {
        generation += 1; let token = generation; let id = config.connectionID
        api?.cancel(); api = nil
        issue("正在读取配置的用量接口", phase: "loading")
        do {
            let url = try RelayRules.validate(config), credential = try RelayKeychain.read(id)
            let client = RelayAPIClient(); api = client
            client.fetch(url: url, credential: credential) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.started, self.generation == token, self.configuration?.connectionID == id else { return }
                    self.api = nil
                    switch result {
                    case .success(let data):
                        do { self.accept(try RelayRules.parseAPI(data, configuration: config), id: id) }
                        catch { self.issue((error as? RelayFailure)?.message ?? "响应字段未通过校验，请检查映射。", phase: "unavailable") }
                    case .failure(let error): self.issue(error.message, phase: "unavailable")
                    }
                }
            }
        } catch { issue((error as? RelayFailure)?.message ?? "无法访问用量接口，请检查设置。", phase: "unavailable") }
    }
    private func accept(_ entries: [RelayEntry], id: String) {
        guard let config = configuration, config.connectionID == id else { return }
        let snapshot = RelaySnapshot(connectionID: id, periodLabel: config.periodLabel, capturedAt: Date(), sourceLabel: config.sourceLabel, status: "live", entries: entries)
        lastSnapshot = snapshot; onSnapshot?(snapshot)
        try? RelayStore.write(snapshot, to: "relay-snapshot.json")
        record("live", "用量已通过校验")
    }
    private func issue(_ reason: String, phase: String) {
        lastIssue = reason; record(phase, reason)
        guard let config = configuration else { emitUnconfigured(); return }
        if var previous = lastSnapshot, previous.connectionID == config.connectionID {
            previous.status = "stale"; previous.sourceLabel = config.sourceLabel; onSnapshot?(previous)
        } else {
            onSnapshot?(RelaySnapshot(connectionID: config.connectionID, periodLabel: config.periodLabel, capturedAt: nil, sourceLabel: config.sourceLabel, status: phase, entries: []))
        }
    }
    private func record(_ phase: String, _ reason: String) {
        guard let config = configuration else { return }
        try? RelayStore.write(Diagnostic(connectionID: config.connectionID, phase: phase, reason: reason, updatedAt: Date()), to: "relay-connection-state.json")
    }
    private func loadCache() {
        guard let config = configuration, let saved = RelayStore.read(RelaySnapshot.self, from: "relay-snapshot.json"),
              let safe = RelayRules.cached(saved, for: config) else { return }
        lastSnapshot = safe; onSnapshot?(safe)
    }
    private func makeBrowser(_ config: RelayConfiguration) {
        guard browser == nil else { return }
        let webConfig = WKWebViewConfiguration(); webConfig.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 700), configuration: webConfig)
        view.navigationDelegate = self; view.uiDelegate = self
        view.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 748), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "中转站登录与用量页"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 720, height: 580); window.center()
        let container = window.contentView!
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 700)
        container.addSubview(view)
        let button = NSButton(title: "打开已配置的用量页", target: self, action: #selector(openConfiguredPage))
        button.frame = NSRect(x: 16, y: 710, width: 190, height: 26); button.autoresizingMask = [.minYMargin]
        container.addSubview(button)
        browser = view; loginWindow = window
        let id = config.connectionID
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in
            guard let self, self.configuration?.connectionID == id else { return }; self.inspectLocation()
        } }
        loadingObservation = view.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in guard let self, self.configuration?.connectionID == id else { return }; self.inspectLocation() }
        }
    }
    @objc private func openConfiguredPage() {
        guard started, let config = configuration, config.mode == .web, let url = try? RelayRules.validate(config) else { return }
        browser?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
    private func isUsagePage(_ url: URL?) -> Bool {
        guard let config = configuration, let expected = try? RelayRules.validate(config) else { return false }
        return RelayRules.exactPage(url, configured: expected)
    }
    private func inspectLocation() {
        guard started, documentCommitted, let browser else { return }
        if isUsagePage(browser.url) { beginReadCycle() }
        else { retryTimer?.invalidate(); retryTimer = nil; issue("请在登录窗口完成登录，然后打开已配置用量页。", phase: "unconnected") }
    }
    private func beginReadCycle() {
        guard started, configuration?.mode == .web, isUsagePage(browser?.url), readerSource != nil else { issue("网页统计模板不可用。", phase: "unavailable"); return }
        retryTimer?.invalidate(); generation += 1; evaluating = false; candidate = nil
        readDeadline = Date().addingTimeInterval(30); earliestAcceptance = Date().addingTimeInterval(2)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.readRenderedCard() } }
        readRenderedCard()
    }
    private func readRenderedCard() {
        guard started, let config = configuration, let browser, let readerSource else { return }
        guard Date() < readDeadline else { retryTimer?.invalidate(); retryTimer = nil; issue("未找到与配置匹配的统计页；请检查周期和模板。", phase: "unavailable"); return }
        guard !evaluating, documentCommitted, isUsagePage(browser.url) else { return }
        evaluating = true
        let token = generation, id = config.connectionID
        let args = ["usageURL": config.usageURL, "periodLabel": config.periodLabel]
        guard let json = try? JSONSerialization.data(withJSONObject: args), let literal = String(data: json, encoding: .utf8) else { evaluating = false; return }
        let script = "(() => { const reader = (\(readerSource))(\(literal)); const action = reader.prepare(); return action.action !== 'none' ? {status:'preparing'} : reader.read(); })()"
        browser.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.started, self.generation == token, self.configuration?.connectionID == id else { return }
                self.evaluating = false
                guard error == nil, let result = value as? [String: Any], let status = result["status"] as? String else { self.candidate = nil; return }
                if status == "preparing" { self.candidate = nil; self.earliestAcceptance = Date().addingTimeInterval(2); return }
                guard status == "ready", result["periodLabel"] as? String == config.periodLabel,
                      let rows = result["entries"] as? [[String: Any]], !rows.isEmpty || result["emptyConfirmed"] as? Bool == true,
                      let signature = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else { self.candidate = nil; return }
                guard self.candidate == signature else { self.candidate = signature; self.candidateSince = Date(); return }
                guard Date() >= self.earliestAcceptance, Date().timeIntervalSince(self.candidateSince) >= 0.8 else { return }
                do {
                    // This template exposes only calls and costs. Token fields remain nil.
                    var mapped = config; mapped.mapping = RelayMapping(entriesPath: "", name: "name", calls: "calls", inputTokens: "", outputTokens: "", totalTokens: "", amountUSD: "amountUSD")
                    self.accept(try RelayRules.parseAPI(signature, configuration: mapped), id: id)
                    self.retryTimer?.invalidate(); self.retryTimer = nil
                } catch { self.issue("网页统计值未通过校验。", phase: "unavailable") }
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browser else { return }
        generation += 1; documentCommitted = false; evaluating = false; candidate = nil
        retryTimer?.invalidate(); retryTimer = nil; issue("网页统计正在同步。", phase: "loading")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { guard started, webView === browser else { return }; documentCommitted = true; inspectLocation() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard started else { return }
        if webView === browser { inspectLocation() }
        else if isUsagePage(webView.url) { popupWindows.first(where: { $0.contentView === webView })?.close(); openConfiguredPage() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ view: WKWebView, _ error: Error) { guard view === browser, (error as NSError).code != NSURLErrorCancelled else { return }; issue("网页连接失败，请检查设置或重新登录。", phase: "unavailable") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { guard webView === browser else { return }; issue("网页已暂停，请刷新重试。", phase: "unavailable") }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Normal HTTPS sign-in navigation is allowed, but only the exact configured
        // usage page is ever inspected. API credentials are never given to WebKit.
        decisionHandler(url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, url.scheme?.lowercased() == "https" else { return nil }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 720), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "中转站登录"; window.isReleasedWhenClosed = false; window.contentView = view
        popupWindows.append(window); window.center(); window.makeKeyAndOrderFront(nil); return view
    }
    func webViewDidClose(_ webView: WKWebView) { popupWindows.first(where: { $0.contentView === webView })?.close() }
}
