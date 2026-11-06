import AppKit
import Foundation

struct DashboardData: Decodable {
    struct Window: Decodable { let key: String?; let label: String?; let remainingPercent: Double?; let usedPercent: Double?; let windowDurationMins: Double?; let resetsAt: Double? }
    struct Credit: Decodable { let expiresAt: Double?; let status: String? }
    struct ResetCredits: Decodable { let availableCount: Double?; let credits: [Credit]? }
    struct Account: Decodable { let status: String?; let updatedAt: String?; let windows: [Window]?; let resetCredits: ResetCredits?; let error: String? }
    struct CPU: Decodable { let usagePercent: Double?; let name: String? }
    struct Memory: Decodable { let usedBytes: Double?; let totalBytes: Double? }
    struct Battery: Decodable { let present: Bool?; let percent: Double?; let charging: Bool?; let onAC: Bool? }
    struct SystemData: Decodable { let updatedAt: String?; let cpu: CPU?; let memory: Memory?; let battery: Battery? }
    struct CodexSpeed: Decodable {
        let status: String?
        let tokensPerSecond: Double?
        let outputTokens: Int?
        let outputDurationMs: Double?
        let updatedAt: String?
        let label: String?
        let detail: String?
        let scopeLabel: String?
    }
    let account: Account?
    let system: SystemData?
    let codexSpeed: CodexSpeed?
    var mainWindow: Window? { account?.windows?.first(where: { $0.windowDurationMins == 10080 }) ?? account?.windows?.first }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WidgetView: NSView {
    static let preferredSize = NSSize(width: 360, height: 454)
    var data: DashboardData? { didSet { needsDisplay = true } }
    var demonstrationDate: Date? { didSet { needsDisplay = true } }
    var isDemo = false { didSet { needsDisplay = true } }
    var connectionError = false { didSet { needsDisplay = true } }
    var showMenu: ((NSView) -> Void)?
    private let gear = NSButton()
    override var isFlipped: Bool { true }
    private let ink = NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.89, alpha: 1)
    private let muted = NSColor(calibratedRed: 0.80, green: 0.78, blue: 0.76, alpha: 0.86)
    var nextResetExpiry: Double? {
        data?.account?.resetCredits?.credits?.filter { $0.status == "available" }
            .compactMap { $0.expiresAt }.filter { $0.isFinite }.min()
    }
    var expiryState: String {
        guard let expiry = nextResetExpiry else { return "unknown" }
        let remaining = expiry - (demonstrationDate ?? Date()).timeIntervalSince1970
        if remaining <= 0 { return "expired" }
        return remaining <= 3 * 24 * 60 * 60 ? "soon" : "normal"
    }
    var displayedSpeedText: String {
        guard !connectionError, data?.codexSpeed?.status == "ready", let speed = data?.codexSpeed?.tokensPerSecond,
              speed.isFinite, speed >= 0 else { return "—" }
        return "≈ " + String(format: "%.1f", speed) + " Token/s"
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gear.frame = NSRect(x: 307, y: 18, width: 30, height: 30)
        gear.isBordered = false
        gear.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "组件设置")
        gear.contentTintColor = ink.withAlphaComponent(0.76)
        gear.imagePosition = .imageOnly
        gear.target = self
        gear.action = #selector(openMenu)
        gear.toolTip = "设置、置顶与退出；拖动空白处移动组件"
        gear.setAccessibilityLabel("组件设置")
        addSubview(gear)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("GPT 桌面组件")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openMenu() { showMenu?(gear) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { showMenu?(self) }

    private func label(_ text: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil, digits: Bool = false, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color ?? ink, .paragraphStyle: style])
    }
    private func rule(y: CGFloat) {
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSRect(x: 24, y: y, width: 312, height: 0.5).fill()
    }
    private func display(_ n: Double?, digits: Int = 0) -> String {
        guard let n, n.isFinite else { return "—" }
        return String(format: "%.*f", digits, n)
    }
    private func localTime(_ date: Date?, format: String) -> String {
        guard let date else { return "未提供" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = format
        return f.string(from: date)
    }
    private func isoTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Opaque base keeps the widget legible even when Reduce Transparency is on.
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
        NSColor(calibratedRed: 0.18, green: 0.15, blue: 0.17, alpha: 0.63).setFill(); bg.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke(); bg.lineWidth = 1; bg.stroke()
        label("✳", NSRect(x: 23, y: 20, width: 25, height: 25), size: 22, color: ink.withAlphaComponent(0.8))
        label("Codex", NSRect(x: 52, y: 23, width: 145, height: 25), size: 18, weight: .semibold)
        label(isDemo ? "虚构示例" : "账号用量", NSRect(x: 127, y: 28, width: 100, height: 19), size: 11, color: muted)
        let window = data?.mainWindow
        label((window?.label ?? "账号额度") + " · 剩余", NSRect(x: 25, y: 66, width: 230, height: 20), size: 12, color: muted)
        let value = display(window?.remainingPercent)
        label(value, NSRect(x: 21, y: 83, width: 180, height: 82), size: 72, weight: .regular, digits: true)
        if window?.remainingPercent != nil {
            let numberWidth = (value as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .regular)]).width
            let percentX: CGFloat = min(188, 24 + numberWidth)
            label("%", NSRect(x: percentX, y: 124, width: 32, height: 31), size: 24, color: ink.withAlphaComponent(0.9))
        }
        label("重置卡", NSRect(x: 254, y: 93, width: 80, height: 18), size: 11, color: muted, align: .right)
        label(display(data?.account?.resetCredits?.availableCount) + " 张", NSRect(x: 243, y: 115, width: 92, height: 36), size: 25, weight: .medium, digits: true, align: .right)
        let track = NSRect(x: 25, y: 171, width: 310, height: 6)
        NSColor.white.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        if let remaining = window?.remainingPercent, remaining.isFinite {
            ink.withAlphaComponent(connectionError || data?.account?.status == "stale" ? 0.45 : 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 25, y: 171, width: 310 * max(0, min(100, remaining)) / 100, height: 6), xRadius: 3, yRadius: 3).fill()
        }
        label("下次重置", NSRect(x: 25, y: 191, width: 85, height: 17), size: 11, color: muted)
        label(localTime(window?.resetsAt.map(Date.init(timeIntervalSince1970:)), format: "MM/dd HH:mm"), NSRect(x: 150, y: 189, width: 185, height: 22), size: 13, digits: true, align: .right)
        let expiry = nextResetExpiry
        let expiryStatus = expiryState
        let expiryHighlighted = expiryStatus == "soon" || expiryStatus == "expired"
        let expiryRed = NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.45, alpha: 1)
        if expiryHighlighted {
            let warningRow = NSBezierPath(roundedRect: NSRect(x: 18, y: 208, width: 324, height: 27), xRadius: 6, yRadius: 6)
            expiryRed.withAlphaComponent(0.13).setFill(); warningRow.fill()
            expiryRed.withAlphaComponent(0.38).setStroke(); warningRow.lineWidth = 0.75; warningRow.stroke()
        }
        let expiryLabel = expiryStatus == "expired" ? "卡片已到期" : expiryStatus == "soon" ? "卡片 3 天内到期" : "最近卡片到期"
        label(expiryLabel, NSRect(x: 25, y: 213, width: 120, height: 17), size: 10, weight: expiryHighlighted ? .semibold : .regular, color: expiryHighlighted ? expiryRed : muted.withAlphaComponent(0.75))
        label(localTime(expiry.map(Date.init(timeIntervalSince1970:)), format: "MM/dd HH:mm"), NSRect(x: 150, y: 211, width: 185, height: 20), size: 11, weight: expiryHighlighted ? .semibold : .regular, color: expiryHighlighted ? expiryRed : muted, digits: true, align: .right)
        rule(y: 244)
        let system = data?.system
        metric(title: "CPU", value: display(system?.cpu?.usagePercent), unit: "%", x: 25, width: 92)
        metric(title: "内存", value: display(system?.memory?.usedBytes.map { $0 / 1073741824 }, digits: 1), unit: "GB", x: 139, width: 92)
        let battery = system?.battery
        metric(title: battery?.present == false ? "供电" : "电量", value: battery?.present == false ? "外接" : display(battery?.percent), unit: battery?.present == false ? "" : "%", x: 252, width: 82)
        rule(y: 319)
        let speed = data?.codexSpeed
        label("最近回复均速", NSRect(x: 25, y: 331, width: 160, height: 18), size: 11, color: muted)
        let speedTime = isoTime(speed?.updatedAt)
        let speedReady = !connectionError && speed?.status == "ready"
        let speedState: String
        if let speedTime {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let today = calendar.isDateInToday(speedTime)
            let clock = localTime(speedTime, format: today ? "HH:mm" : "MM/dd HH:mm")
            let scope = speed?.scopeLabel.map { String($0.prefix(12)) } ?? ""
            speedState = speedReady ? (!today ? "上次 " + clock : (scope.isEmpty ? clock : scope + " · " + clock)) : "旧读数 " + clock
        } else { speedState = speedReady ? "时间未提供" : (speed?.status == "unavailable" || connectionError ? "暂不可测" : "等待回复完成") }
        label(speedState, NSRect(x: 182, y: 332, width: 153, height: 17), size: 9, color: muted, digits: true, align: .right)
        label(displayedSpeedText, NSRect(x: 25, y: 350, width: 310, height: 32), size: 25, weight: .medium, digits: true)
        let suppliedDetail = speed?.detail.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        let speedDetail = speed?.status == "ready" ? "回复结束后更新 · 不含思考与工具等待"
            : (suppliedDetail ?? "回复结束后更新 · 不含思考与工具等待")
        label(speedDetail, NSRect(x: 25, y: 383, width: 310, height: 15), size: 9, color: muted)
        rule(y: 405)
        let updated = isoTime(data?.account?.updatedAt)
        let systemUpdated = isoTime(data?.system?.updatedAt)
        let oldSystem = systemUpdated.map { (demonstrationDate ?? Date()).timeIntervalSince($0) > 60 } ?? true
        let staleAccount = data?.account?.status != "live" || (updated.map { (demonstrationDate ?? Date()).timeIntervalSince($0) > 360 } ?? true)
        let status: String
        if isDemo { status = "示例数据 · 不连接真实账号" }
        else if connectionError { status = "连接已中断 · 保留最近读数" }
        else if staleAccount { status = updated == nil ? (data?.account?.error == nil ? "正在连接账号…" : "账号暂未连接") : "额度同步暂缓 · " + localTime(updated, format: "HH:mm") }
        else if oldSystem { status = "电脑状态待同步" }
        else { status = "额度 " + localTime(updated, format: "HH:mm") + " · 每 5 分钟更新" }
        let dot = NSBezierPath(ovalIn: NSRect(x: 25, y: 427, width: 5, height: 5))
        if connectionError || staleAccount || oldSystem { muted.setStroke(); dot.lineWidth = 1; dot.stroke() }
        else { ink.withAlphaComponent(0.8).setFill(); dot.fill() }
        label(status, NSRect(x: 37, y: 420, width: 270, height: 20), size: 10, color: muted)
        let expiryAnnouncement = expiryHighlighted ? "。\(expiryLabel)" : ""
        setAccessibilityValue("Codex，\(window?.label ?? "额度")剩余 \(value)%，重置卡 \(display(data?.account?.resetCredits?.availableCount)) 张\(expiryAnnouncement)。最近回复均速 \(displayedSpeedText)。\(speedDetail)。\(status)")
    }
    private func metric(title: String, value: String, unit: String, x: CGFloat, width: CGFloat) {
        label(title, NSRect(x: x, y: 258, width: width, height: 17), size: 11, color: muted)
        label(value + (unit.isEmpty ? "" : " " + unit), NSRect(x: x, y: 278, width: width + 8, height: 29), size: 21, weight: .medium, digits: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let backend = BackendController()
    let relay = RelayConnection()
    let sharing = SharingController()
    var panel: WidgetPanel!
    var widget: WidgetView!
    var relayPanel: WidgetPanel!
    var relayView: RelayView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var backendTimer: Timer?
    var inFlight = false
    var snapshotPath: String?
    var snapshotTarget = "codex"
    var snapshotDone = false
    var demoMode = false
    var demoPin = true
    var alwaysOnTop: Bool { if demoMode { return demoPin }; return UserDefaults.standard.object(forKey: "alwaysOnTop") == nil ? true : UserDefaults.standard.bool(forKey: "alwaysOnTop") }
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 { snapshotPath = args[index+1] }
        if let index = args.firstIndex(of: "--snapshot-codex"), args.count > index + 1 { snapshotPath = args[index+1] }
        if let index = args.firstIndex(of: "--snapshot-relay"), args.count > index + 1 { snapshotPath = args[index+1]; snapshotTarget = "relay" }
        demoMode = args.contains("--demo") || snapshotPath != nil
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createRelayPanel()
        createStatusItem()
        if demoMode {
            widget.isDemo = true; relayView.isDemo = true
            loadDemo()
            if snapshotPath != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.exportSnapshot() } }
            return
        }
        sharing.onStateChange = { [weak self] in self?.refreshMenus() }
        if snapshotPath == nil { sharing.startIfEnabled() }
        relay.onSnapshot = { [weak self] value in
            guard let self else { return }
            self.relayView.snapshot = value
            if self.snapshotPath != nil && self.snapshotTarget == "relay" && self.relayView.displayedTotalUSD != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.exportSnapshot() }
            }
        }
        relay.start()
        backend.ensureRunning()
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.fetch() } }
        backendTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.backend.ensureRunning() } }
        if args.contains("--connect-relay") && snapshotPath == nil { relay.showLogin() }
        if snapshotPath != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in self?.exportSnapshot() } }
    }
    private func makePanel(frame: NSRect, title: String) -> WidgetPanel {
        let result = WidgetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        result.title = title
        result.backgroundColor = .clear
        result.isOpaque = false
        result.hasShadow = true
        result.hidesOnDeactivate = false
        result.isMovableByWindowBackground = true
        WidgetWindowPolicy.apply(to: result, pinned: alwaysOnTop)
        result.delegate = self
        return result
    }
    private func backdrop(size: NSSize) -> NSVisualEffectView {
        let result = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        result.material = .hudWindow
        result.blendingMode = .behindWindow
        result.state = .active
        result.appearance = NSAppearance(named: .darkAqua)
        result.wantsLayer = true
        result.layer?.cornerRadius = 28
        result.layer?.masksToBounds = true
        return result
    }
    func createPanel() {
        let size = WidgetView.preferredSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = NSRect(x: screen.maxX-size.width-26, y: screen.maxY-size.height-26, width: size.width, height: size.height)
        panel = makePanel(frame: initial, title: "Codex 桌面组件")
        let background = backdrop(size: size)
        widget = WidgetView(frame: background.bounds)
        widget.autoresizingMask = [.width, .height]
        widget.showMenu = { [weak self] anchor in self?.showContextMenu(anchor) }
        background.addSubview(widget)
        panel.contentView = background
        if !demoMode {
            panel.setFrameAutosaveName("GPTDesktopWidgetFrame")
            panel.setFrameUsingName("GPTDesktopWidgetFrame")
        }
        let restored = panel.frame
        panel.setFrame(NSRect(x: restored.minX, y: restored.maxY-size.height, width: size.width, height: size.height), display: false)
        clampToScreens(panel)
        WidgetWindowPolicy.show(panel, pinned: alwaysOnTop)
    }
    func createRelayPanel() {
        let size = RelayView.preferredSize
        let frame = suggestedRelayFrame()
        relayPanel = makePanel(frame: frame, title: "中转站 Token 用量")
        let background = backdrop(size: size)
        relayView = RelayView(frame: background.bounds)
        relayView.autoresizingMask = [.width, .height]
        relayView.showMenu = { [weak self] anchor in self?.showContextMenu(anchor) }
        background.addSubview(relayView)
        relayPanel.contentView = background
        if !demoMode {
            relayPanel.setFrameAutosaveName("RelayDesktopWidgetFrame")
            relayPanel.setFrameUsingName("RelayDesktopWidgetFrame")
        }
        clampToScreens(relayPanel)
        WidgetWindowPolicy.show(relayPanel, pinned: alwaysOnTop)
    }
    private func suggestedRelayFrame() -> NSRect {
        let size = RelayView.preferredSize
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 18
        let left = panel.frame.minX-size.width-gap
        if left >= screen.minX+8 {
            return NSRect(x: left, y: panel.frame.maxY-size.height, width: size.width, height: size.height)
        }
        return NSRect(x: panel.frame.minX, y: panel.frame.minY-size.height-gap, width: size.width, height: size.height)
    }
    func clampToScreens(_ target: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(target.frame) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        var frame = target.frame
        frame.origin.x = min(max(frame.minX, area.minX+8), area.maxX-frame.width-8)
        frame.origin.y = min(max(frame.minY, area.minY+8), area.maxY-frame.height-8)
        target.setFrame(frame, display: true)
    }
    func windowDidMove(_ notification: Notification) {
        guard !demoMode, let moved = notification.object as? NSWindow else { return }
        if moved === panel { moved.saveFrame(usingName: "GPTDesktopWidgetFrame") }
        else if moved === relayPanel { moved.saveFrame(usingName: "RelayDesktopWidgetFrame") }
    }
    func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◈ —"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.toolTip = "Codex 与中转站桌面组件"
        statusItem.menu = makeMenu()
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let codexToggle = NSMenuItem(title: panel.isVisible ? "隐藏 Codex 组件" : "显示 Codex 组件", action: #selector(toggleVisible), keyEquivalent: "")
        codexToggle.target = self; menu.addItem(codexToggle)
        let relayToggle = NSMenuItem(title: relayPanel.isVisible ? "隐藏中转站组件" : "显示中转站组件", action: #selector(toggleRelayVisible), keyEquivalent: "")
        relayToggle.target = self; menu.addItem(relayToggle)
        let pin = NSMenuItem(title: "始终置顶", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self; pin.state = alwaysOnTop ? .on : .off; menu.addItem(pin)
        menu.addItem(.separator())
        for (title, action) in [("刷新 Codex 显示", #selector(refreshDisplay)), ("打开完整 Codex 看板", #selector(openDashboard)), ("移动组件到当前屏幕", #selector(moveToCurrentScreen))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("中转站设置…", #selector(configureRelay)), ("打开中转站登录页", #selector(connectRelay)), ("刷新中转站", #selector(refreshRelay))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let openSharing = NSMenuItem(title: "在 iPad / Kindle 打开…", action: #selector(openDeviceSharing), keyEquivalent: "")
        openSharing.target = self; menu.addItem(openSharing)
        let closeSharing = NSMenuItem(title: "关闭设备共享", action: #selector(closeDeviceSharing), keyEquivalent: "")
        closeSharing.target = self; closeSharing.isEnabled = !demoMode && sharing.isEnabled; menu.addItem(closeSharing)
        let project = NSMenuItem(title: "项目源码与许可", action: #selector(openProjectSource), keyEquivalent: "")
        project.target = self; menu.addItem(project)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "拖动空白处移动 · 账号每 5 分钟同步", action: nil, keyEquivalent: ""); hint.isEnabled = false; menu.addItem(hint)
        let quit = NSMenuItem(title: "退出桌面组件", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        return menu
    }
    func showContextMenu(_ anchor: NSView) { makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor) }
    func refreshMenus() { statusItem.menu = makeMenu() }
    @objc func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { clampToScreens(panel); WidgetWindowPolicy.show(panel, pinned: alwaysOnTop) }
        refreshMenus()
    }
    @objc func toggleRelayVisible() {
        if relayPanel.isVisible { relayPanel.orderOut(nil) } else { clampToScreens(relayPanel); WidgetWindowPolicy.show(relayPanel, pinned: alwaysOnTop) }
        refreshMenus()
    }
    @objc func togglePin() {
        if demoMode { demoPin.toggle() } else { UserDefaults.standard.set(!alwaysOnTop, forKey: "alwaysOnTop") }
        for card in [panel, relayPanel] {
            guard let card else { continue }
            let visible = card.isVisible
            WidgetWindowPolicy.apply(to: card, pinned: alwaysOnTop)
            if visible { WidgetWindowPolicy.show(card, pinned: alwaysOnTop) }
        }
        refreshMenus()
    }
    @objc func refreshDisplay() { if demoMode { loadDemo(); return }; backend.ensureRunning(); fetch() }
    @objc func openDashboard() { guard !demoMode else { return }; NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8768/")!) }
    @objc func configureRelay() { if !demoMode { relay.showSettings() } }
    @objc func connectRelay() { if !demoMode { relay.showLogin() } }
    @objc func openDeviceSharing() { if !demoMode { backend.ensureRunning(); sharing.showInstructions() } }
    @objc func closeDeviceSharing() { if !demoMode { sharing.disable() } }
    @objc func openProjectSource() { NSWorkspace.shared.open(URL(string: "https://github.com/areslnn/didi_don_not_forget")!) }
    @objc func refreshRelay() { if demoMode { loadDemo() } else { relay.refresh() } }
    @objc func moveToCurrentScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.maxX-panel.frame.width-26, y: area.maxY-panel.frame.height-26))
        relayPanel.setFrame(suggestedRelayFrame(), display: true)
        clampToScreens(relayPanel)
        WidgetWindowPolicy.show(panel, pinned: alwaysOnTop); WidgetWindowPolicy.show(relayPanel, pinned: alwaysOnTop); refreshMenus()
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func fetch() {
        guard !inFlight else { return }
        inFlight = true
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8768/api/dashboard")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] bytes, response, error in
            var value: DashboardData?
            if let response = response as? HTTPURLResponse, response.statusCode == 200, response.value(forHTTPHeaderField: "X-Dashboard") == "gpt-mac-local", let bytes, error == nil {
                value = try? JSONDecoder().decode(DashboardData.self, from: bytes)
            }
            let result = value
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                if let result {
                    self.widget.data = result
                    self.widget.connectionError = false
                    if let percent = result.mainWindow?.remainingPercent { self.statusItem.button?.title = "◈ \(Int(percent.rounded()))%" }
                    else { self.statusItem.button?.title = "◈ —" }
                    if self.snapshotPath != nil && self.snapshotTarget == "codex" && result.mainWindow?.remainingPercent != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.exportSnapshot() }
                    }
                } else { self.widget.connectionError = true; self.statusItem.button?.title = "◈ ···" }
            }
        }.resume()
    }
    private func loadDemo() {
        guard demoMode, let url = Bundle.main.url(forResource: "demo", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), bytes.count <= RelayRules.maxBody,
              let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], root["demo"] as? Bool == true,
              let dashboard = try? JSONDecoder().decode(DashboardData.self, from: bytes) else { return }
        widget.data = dashboard; widget.connectionError = false
        let date = (root["fetchedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        widget.demonstrationDate = date
        statusItem.button?.title = "◈ 示例"
        guard let provider = root["relay"] as? [String: Any], let entries = provider["entries"],
              let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        let config = RelayConfiguration(connectionID: "00000000-0000-4000-8000-000000000001", mode: .api,
            displayName: "示例中转站", usageURL: "https://example.invalid/usage", periodLabel: provider["periodLabel"] as? String ?? "示例周期", mapping: RelayMapping(entriesPath: ""))
        guard let normalized = try? RelayRules.parseAPI(data, configuration: config) else { return }
        relayView.snapshot = RelaySnapshot(connectionID: config.connectionID, periodLabel: config.periodLabel,
            capturedAt: date, sourceLabel: "示例中转站", status: "live", entries: normalized)
    }
    func exportSnapshot() {
        guard !snapshotDone, let path = snapshotPath else { return }
        snapshotDone = true
        let target = snapshotTarget == "relay" ? relayPanel! : panel!
        guard let view = target.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        var diagnostics: [String: Any] = [
            "target": snapshotTarget,
            "demo": demoMode,
            "windowLevel": target.level.rawValue,
            "alwaysOnTop": alwaysOnTop,
            "canJoinAllSpaces": target.collectionBehavior.contains(.canJoinAllSpaces),
            "fullScreenAuxiliary": target.collectionBehavior.contains(.fullScreenAuxiliary),
            "movableByWindowBackground": target.isMovableByWindowBackground,
            "visible": target.isVisible,
            "width": target.frame.width,
            "height": target.frame.height,
            "snapshotSaved": FileManager.default.fileExists(atPath: path)
        ]
        if snapshotTarget == "relay" {
            diagnostics["sourceLabel"] = relayView.snapshot?.sourceLabel ?? "Relay"
            diagnostics["accountStatus"] = relayView.snapshot?.status ?? "unconnected"
            diagnostics["periodLabel"] = relayView.snapshot?.periodLabel ?? ""
            diagnostics["entriesCount"] = relayView.snapshot?.entries.count ?? 0
            diagnostics["totalUSD"] = relayView.displayedTotalUSD as Any? ?? NSNull()
            diagnostics["totalTokens"] = relayView.displayedTotalTokens as Any? ?? NSNull()
            diagnostics["demo"] = demoMode
            diagnostics["totalCalls"] = relayView.displayedTotalCalls as Any? ?? NSNull()
            diagnostics["accessibilityValue"] = relayView.accessibilityValue() ?? ""
        } else {
            diagnostics["accountStatus"] = widget.data?.account?.status ?? "unavailable"
            diagnostics["remainingPercent"] = widget.data?.mainWindow?.remainingPercent as Any? ?? NSNull()
            diagnostics["resetCards"] = widget.data?.account?.resetCredits?.availableCount as Any? ?? NSNull()
            diagnostics["resetExpiryState"] = widget.expiryState
            diagnostics["connectionError"] = widget.connectionError
            diagnostics["accessibilityValue"] = widget.accessibilityValue() ?? ""
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) { try? bytes.write(to: URL(fileURLWithPath: path + ".json")) }
        NSApp.terminate(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // App activation may accompany accessibility clicks. Reordering panels or
        // replacing the status menu here would interrupt an open menu/login form.
        guard !flag, panel?.isVisible != true, relayPanel?.isVisible != true else { return false }
        guard !sender.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return false }
        for card in [panel, relayPanel] {
            guard let card else { continue }
            clampToScreens(card)
            WidgetWindowPolicy.show(card, pinned: alwaysOnTop)
        }
        refreshMenus()
        return false // This delegate has handled the reopen; suppress default ordering.
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); backendTimer?.invalidate(); session.invalidateAndCancel(); sharing.stop(); relay.stop(); backend.stop() }
}

@main
struct WidgetApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
