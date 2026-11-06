import AppKit
import Foundation
import WebKit

/// Owns a normal, app-local WebKit login session. It never reads Safari data,
/// cookies, browser storage, credentials, or private API responses.
@MainActor
final class StarsgConnection: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onSnapshot: ((StarsgSnapshot) -> Void)?
    private let usageURL = URL(string: "https://starsg.ai/app/usage?line=llm")!
    private var browser: WKWebView?
    private var loginWindow: NSWindow?
    private var popupWindows: [NSWindow] = []
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var locationTimer: Timer?
    private var locationDeadline = Date.distantPast
    private var refreshTimer: Timer?
    private var retryTimer: Timer?
    private var started = false
    private var generation = 0
    private var evaluating = false
    private var documentCommitted = false
    private var deadline = Date.distantPast
    private var earliestAcceptance = Date.distantPast
    private var candidate: Data?
    private var candidateSince = Date.distantPast
    private var lastSnapshot: StarsgSnapshot?
    private var lastIssue = "待连接自动更新"
    private var readerSource: String?

    private struct SavedEntry: Codable {
        let name: String
        let calls: Int
        let amountUSD: Double
        let sharePercent: Double
    }
    private struct SavedSnapshot: Codable {
        let periodLabel: String
        let capturedAt: String?
        let sourceLabel: String?
        let status: String?
        let entries: [SavedEntry]
    }
    private var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.aiusagedashboard", isDirectory: true)
            .appendingPathComponent("starsg-snapshot.json")
    }

    func start() {
        guard !started else { return }
        started = true
        readerSource = Bundle.main.url(forResource: "StarsgReader", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        loadSavedSnapshot()
        if lastSnapshot == nil { issue("待连接自动更新", status: "unconnected") }
        makeBrowser()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        loadUsagePage()
    }

    func showLogin() {
        if !started { start() }
        guard let window = loginWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if browser?.url == nil { loadUsagePage() }
        else if isStarsgAppPage(browser?.url) { observedLocationChanged() }
    }

    func refresh() {
        guard started, let browser else { return }
        // Let a user finish the normal sign-in form without periodic reloads.
        if loginWindow?.isVisible == true, !isStarsgAppPage(browser.url) { return }
        if isUsagePage(browser.url) { browser.reload() }
        else { loadUsagePage() }
    }

    func stop() {
        started = false
        generation += 1
        refreshTimer?.invalidate(); refreshTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        locationTimer?.invalidate(); locationTimer = nil
        urlObservation?.invalidate(); urlObservation = nil
        loadingObservation?.invalidate(); loadingObservation = nil
        browser?.stopLoading()
        browser?.navigationDelegate = nil
        browser?.uiDelegate = nil
        popupWindows.forEach { ($0.contentView as? WKWebView)?.stopLoading(); $0.close() }
        popupWindows.removeAll()
        loginWindow?.close()
        loginWindow = nil
        browser = nil
        evaluating = false
        documentCommitted = false
    }

    private func makeBrowser() {
        let configuration = WKWebViewConfiguration()
        // WebKit maintains this app's own standard persistent sign-in store.
        // No API for enumerating or exporting its cookies is used.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 740), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "连接 Starsg"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 560)
        window.contentView = view
        window.center()
        browser = view
        loginWindow = window
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.observedLocationChanged()
            }
        }
        loadingObservation = view.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in
                self?.observedLocationChanged()
            }
        }
    }

    private func loadUsagePage() {
        guard started else { return }
        browser?.load(URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    private func isUsagePage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "starsg.ai", url.path == "/app/usage" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "line" && $0.value == "llm" }) == true
    }

    private func isStarsgAppPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "starsg.ai" else { return false }
        return url.path == "/app" || url.path.hasPrefix("/app/")
    }

    private func observedLocationChanged() {
        guard started else { return }
        locationDeadline = Date().addingTimeInterval(30)
        inspectLocation()
    }

    private func scheduleLocationCheck() {
        guard started, Date() < locationDeadline, locationTimer == nil else { return }
        locationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.locationTimer = nil
                self.inspectLocation()
            }
        }
    }

    private func inspectLocation() {
        guard started, let browser, let url = browser.url else { return }
        // A third-party frame can keep isLoading true after the app is usable.
        // Only require a committed main document; the DOM reader separately
        // checks the visible period, tab, loading indicators, and complete graph.
        if !documentCommitted { scheduleLocationCheck(); return }
        locationTimer?.invalidate(); locationTimer = nil
        recordState("location_ready", reason: "")
        if isUsagePage(url) { beginReadCycle(); return }
        retryTimer?.invalidate(); retryTimer = nil
        if isStarsgAppPage(url) { recordState("routing_to_usage", reason: "登录已完成，打开用量页"); loadUsagePage(); return }
        issue("请登录 Starsg 连接自动更新", status: "unconnected")
    }

    private func beginReadCycle() {
        guard started, isUsagePage(browser?.url), readerSource != nil else {
            issue("读取组件暂不可用", status: "unavailable"); return
        }
        retryTimer?.invalidate()
        generation += 1
        evaluating = false
        candidate = nil
        candidateSince = .distantPast
        deadline = Date().addingTimeInterval(30)
        earliestAcceptance = Date().addingTimeInterval(2)
        lastIssue = "平台统计正在加载"
        recordState("reading", reason: lastIssue)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readRenderedCard() }
        }
        readRenderedCard()
    }

    private func readRenderedCard() {
        guard started, let browser, let source = readerSource else { return }
        guard Date() < deadline else {
            retryTimer?.invalidate(); retryTimer = nil
            issue(lastIssue, status: "unavailable")
            return
        }
        guard !evaluating, documentCommitted, isUsagePage(browser.url) else { return }
        evaluating = true
        let requestGeneration = generation
        let script = "(() => { const reader = \(source); const result = reader.prepare(); if (result.action !== 'none') return {status:'preparing', action:result.action}; return reader.read(); })()"
        browser.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.started, self.generation == requestGeneration else { return }
                self.evaluating = false
                guard error == nil, let result = value as? [String: Any], let status = result["status"] as? String else {
                    self.candidate = nil
                    self.lastIssue = "页面读取暂未成功"
                    self.recordState("read_error", reason: self.lastIssue)
                    return
                }
                if status == "preparing" {
                    self.candidate = nil
                    self.earliestAcceptance = Date().addingTimeInterval(2)
                    self.lastIssue = "正在切换最近30天统计"
                    self.recordState("preparing", reason: result["action"] as? String ?? self.lastIssue)
                    return
                }
                guard status == "ready", result["periodLabel"] as? String == "最近30天",
                      let rows = result["entries"] as? [[String: Any]],
                      !rows.isEmpty || result["emptyConfirmed"] as? Bool == true,
                      let signature = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else {
                    self.candidate = nil
                    self.lastIssue = (result["reason"] as? String) ?? "平台统计尚未就绪"
                    self.recordState("waiting_for_graph", reason: self.lastIssue)
                    return
                }
                // Require the same visible, validated graph twice after controls settle.
                guard self.candidate == signature else {
                    self.candidate = signature
                    self.candidateSince = Date()
                    self.recordState("verifying_graph", reason: "等待再次核对可见统计")
                    return
                }
                guard Date() >= self.earliestAcceptance, Date().timeIntervalSince(self.candidateSince) >= 0.8 else { return }
                guard let entries = self.validatedEntries(rows) else {
                    self.lastIssue = "统计值未通过校验"
                    return
                }
                let snapshot = StarsgSnapshot(periodLabel: "最近30天", capturedAt: Date(), sourceLabel: "Starsg控制台", status: "live", entries: entries)
                self.lastSnapshot = snapshot
                self.recordState("live", reason: "统计已通过校验")
                self.onSnapshot?(snapshot)
                self.save(snapshot)
                self.retryTimer?.invalidate(); self.retryTimer = nil
            }
        }
    }

    private func validatedEntries(_ rows: [[String: Any]]) -> [StarsgEntry]? {
        guard rows.count <= 100 else { return nil }
        var entries: [StarsgEntry] = []
        var callsTotal = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty, name.count <= 120,
                  let callsNumber = row["calls"] as? NSNumber,
                  let amount = row["amountUSD"] as? Double,
                  let share = row["sharePercent"] as? Double else { return nil }
            let callsDouble = callsNumber.doubleValue
            guard callsDouble.isFinite, callsDouble >= 0, callsDouble.rounded() == callsDouble,
                  callsDouble <= 9_007_199_254_740_991,
                  amount.isFinite, amount >= 0, share.isFinite, share >= 0, share <= 100 else { return nil }
            let calls = callsNumber.intValue
            let (newTotal, overflow) = callsTotal.addingReportingOverflow(calls)
            guard !overflow else { return nil }
            callsTotal = newTotal
            entries.append(StarsgEntry(name: name, calls: calls, amountUSD: amount, sharePercent: share))
        }
        let cost = entries.reduce(0.0) { $0 + $1.amountUSD }
        guard cost.isFinite else { return nil }
        for entry in entries {
            let expected = cost > 0 ? 100 * entry.amountUSD / cost : 0
            guard abs(expected - entry.sharePercent) <= 0.11 else { return nil }
        }
        return entries
    }

    private func issue(_ message: String, status: String) {
        lastIssue = message
        recordState(status, reason: message)
        if let saved = lastSnapshot {
            // An independently verified one-time seed stays labelled one-time.
            let seeded = saved.status == "snapshot"
            onSnapshot?(StarsgSnapshot(periodLabel: saved.periodLabel, capturedAt: saved.capturedAt,
                sourceLabel: seeded ? saved.sourceLabel : "Starsg控制台 · " + message,
                status: seeded ? "snapshot" : "stale", entries: saved.entries))
        } else {
            onSnapshot?(StarsgSnapshot(periodLabel: "最近30天", capturedAt: nil,
                sourceLabel: "Starsg控制台 · " + message, status: status, entries: []))
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func loadSavedSnapshot() {
        let paths = [cacheURL].compactMap { $0 }
        for path in paths {
            guard let data = try? Data(contentsOf: path), data.count < 256_000,
                  let saved = try? JSONDecoder().decode(SavedSnapshot.self, from: data),
                  saved.periodLabel.replacingOccurrences(of: " ", with: "") == "最近30天",
                  let date = Self.parseDate(saved.capturedAt) else { continue }
            let rows: [[String: Any]] = saved.entries.map {
                ["name": $0.name, "calls": $0.calls, "amountUSD": $0.amountUSD, "sharePercent": $0.sharePercent]
            }
            guard let entries = validatedEntries(rows), date <= Date().addingTimeInterval(60) else { continue }
            if let previous = lastSnapshot?.capturedAt, previous >= date { continue }
            lastSnapshot = StarsgSnapshot(periodLabel: "最近30天", capturedAt: date,
                sourceLabel: saved.sourceLabel ?? "Starsg控制台", status: saved.status == "snapshot" ? "snapshot" : "stale", entries: entries)
        }
        if let lastSnapshot { onSnapshot?(lastSnapshot) }
    }

    private func save(_ snapshot: StarsgSnapshot) {
        guard let cacheURL, let date = snapshot.capturedAt else { return }
        let saved = SavedSnapshot(periodLabel: snapshot.periodLabel, capturedAt: ISO8601DateFormatter().string(from: date),
            sourceLabel: "Starsg控制台", status: "live", entries: snapshot.entries.map {
                SavedEntry(name: $0.name, calls: $0.calls, amountUSD: $0.amountUSD, sharePercent: $0.sharePercent)
            })
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* Displayed data remains valid; no credentials or raw DOM are persisted. */ }
    }

    /// Small, app-owned diagnostic state; never raw DOM, URLs with queries,
    /// identifiers, account rows, credentials, or WebKit storage.
    private func recordState(_ phase: String, reason: String) {
        guard let directory = cacheURL?.deletingLastPathComponent() else { return }
        let knownPaths = ["/", "/login", "/app", "/app/overview", "/app/usage"]
        let path: String
        if let url = browser?.url, url.host == "starsg.ai", knownPaths.contains(url.path) { path = url.path }
        else { path = browser?.url == nil ? "not_loaded" : "sign_in_or_other_page" }
        let state: [String: String] = ["phase": phase, "reason": reason, "locationPath": path,
                                       "updatedAt": ISO8601DateFormatter().string(from: Date())]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("starsg-connection-state.json")
            try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browser else { return }
        generation += 1
        evaluating = false
        documentCommitted = false
        candidate = nil
        locationDeadline = Date().addingTimeInterval(30)
        retryTimer?.invalidate(); retryTimer = nil
        issue("正在同步，平台统计可能延迟", status: "loading")
        scheduleLocationCheck()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard started, webView === browser else { return }
        documentCommitted = true
        recordState("document_ready", reason: "主页面已载入，等待可见统计")
        observedLocationChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard started else { return }
        if webView === browser { observedLocationChanged() }
        else if webView.url?.host == "starsg.ai", webView.url?.path == "/app" || webView.url?.path.hasPrefix("/app/") == true {
            popupWindows.first(where: { $0.contentView === webView })?.close()
            loadUsagePage()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ webView: WKWebView, _ error: Error) {
        guard webView === browser, (error as NSError).code != NSURLErrorCancelled else { return }
        issue("连接暂未成功，请检查网络或重新登录", status: "unavailable")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === browser else { return }
        issue("页面已暂停，点刷新重试", status: "unavailable")
    }

    private func allowedNavigation(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "starsg.ai" || host.hasSuffix(".starsg.ai") || host == "accounts.google.com" || host == "appleid.apple.com"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if allowedNavigation(url) { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, allowedNavigation(url) else { return nil }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 720), configuration: configuration)
        popup.navigationDelegate = self; popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Starsg 登录"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        popupWindows.append(window)
        window.center(); window.makeKeyAndOrderFront(nil)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { popupWindows.first(where: { $0.contentView === webView })?.close() }
}
