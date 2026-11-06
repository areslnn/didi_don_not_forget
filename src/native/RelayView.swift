import AppKit
import Foundation

private enum RelayStyle {
    static let ink = NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.89, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.80, green: 0.78, blue: 0.76, alpha: 0.86)
    static let rowHeight: CGFloat = 50
    static func text(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = ink, digits: Bool = false, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.alignment = align; style.lineBreakMode = .byTruncatingTail
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    static func count(_ n: Int?) -> String { n.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) } ?? "未提供" }
    static func money(_ n: Double?, precision: Int) -> String {
        guard let n else { return "费用未提供" }
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal
        f.minimumFractionDigits = precision; f.maximumFractionDigits = precision
        return "$" + (f.string(from: NSNumber(value: n)) ?? "—")
    }
}
@MainActor
private final class RelayRowsView: NSView {
    var entries: [RelayEntry] = [] { didSet { needsDisplay = true } }
    var emptyMessage = "尚未配置中转站" { didSet { needsDisplay = true } }
    var emptyDetail = "在菜单中打开“中转站设置…”" { didSet { needsDisplay = true } }
    var showMenu: ((NSView) -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { showMenu?(self) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if entries.isEmpty {
            RelayStyle.text(emptyMessage, in: NSRect(x: 0, y: 64, width: bounds.width, height: 24), size: 14, weight: .medium, align: .center)
            RelayStyle.text(emptyDetail, in: NSRect(x: 0, y: 93, width: bounds.width, height: 22), size: 10, color: RelayStyle.muted, align: .center)
            return
        }
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index) * RelayStyle.rowHeight
            guard NSRect(x: 0, y: y, width: bounds.width, height: RelayStyle.rowHeight).intersects(dirtyRect) else { continue }
            let width = bounds.width - 5
            RelayStyle.text(entry.name, in: NSRect(x: 0, y: y, width: 150, height: 20), size: 13, weight: .medium)
            RelayStyle.text(RelayStyle.money(entry.amountUSD, precision: 6), in: NSRect(x: 154, y: y+1, width: width-154, height: 19), size: 11, digits: true, align: .right)
            let tokenText = entry.totalTokens == nil && (entry.inputTokens != nil || entry.outputTokens != nil)
                ? "输入 " + (entry.inputTokens.map { RelayStyle.count($0) } ?? "—") + " · 输出 " + (entry.outputTokens.map { RelayStyle.count($0) } ?? "—")
                : "Token " + RelayStyle.count(entry.totalTokens)
            RelayStyle.text(tokenText, in: NSRect(x: 0, y: y+23, width: 195, height: 17), size: 11, color: RelayStyle.muted, digits: true)
            RelayStyle.text(entry.calls.map { RelayStyle.count($0) + " 次调用" } ?? "调用未提供", in: NSRect(x: 194, y: y+23, width: width-194, height: 17), size: 10, color: RelayStyle.muted, digits: true, align: .right)
            NSColor.white.withAlphaComponent(0.10).setFill(); NSRect(x: 0, y: y+46, width: width, height: 0.5).fill()
        }
    }
}

@MainActor
final class RelayView: NSView {
    static let preferredSize = NSSize(width: 360, height: 454)
    var snapshot: RelaySnapshot? { didSet { updateContents() } }
    var isDemo = false { didSet { needsDisplay = true } }
    var showMenu: ((NSView) -> Void)? { didSet { rows.showMenu = showMenu } }
    private let gear = NSButton(), scroll = NSScrollView(), rows = RelayRowsView(frame: .zero)
    override var isFlipped: Bool { true }
    var displayedTotalUSD: Double? { snapshot?.totalUSD }
    var displayedTotalCalls: Int? { snapshot?.totalCalls }
    var displayedTotalTokens: Int? { snapshot?.totalTokens }
    var visibleStatusText: String {
        if isDemo { return "示例数据 · 不连接真实账号" }
        switch snapshot?.status {
        case "live": return "已同步"
        case "stale": return "同步暂缓 · 保留最近读数"
        case "snapshot": return "单次读数 · 待连接自动更新"
        case "loading": return "正在读取用量…"
        case "unconfigured", nil: return "尚未配置中转站"
        case "unconnected": return "请检查登录或访问凭据"
        default: return "用量暂不可用，请检查设置"
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        gear.frame = NSRect(x: 307, y: 18, width: 30, height: 30); gear.isBordered = false
        gear.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "中转站设置")
        gear.contentTintColor = RelayStyle.ink.withAlphaComponent(0.76); gear.imagePosition = .imageOnly
        gear.target = self; gear.action = #selector(openMenu); gear.toolTip = "设置与操作；拖动空白处移动组件"
        gear.setAccessibilityLabel("中转站设置"); addSubview(gear)
        scroll.frame = NSRect(x: 24, y: 199, width: 312, height: 200)
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.contentView.drawsBackground = false
        rows.frame = NSRect(x: 0, y: 0, width: 312, height: 200); scroll.documentView = rows; addSubview(scroll)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("中转站 Token 用量看板")
        updateContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openMenu() { showMenu?(gear) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { showMenu?(self) }
    private func updateContents() {
        let entries = snapshot?.hasReadings == true ? snapshot?.entries ?? [] : []
        rows.entries = entries; rows.frame = NSRect(x: 0, y: 0, width: 312, height: max(200, CGFloat(entries.count) * RelayStyle.rowHeight))
        if snapshot?.status == "live", entries.isEmpty {
            rows.emptyMessage = "该期间没有用量记录"; rows.emptyDetail = "来源确认返回空列表"
        } else {
            rows.emptyMessage = visibleStatusText
            rows.emptyDetail = snapshot?.status == "unconfigured" || snapshot == nil ? "在菜单中打开“中转站设置…”" : "未知值保持未提供，不按费用推算 Token"
        }
        if scroll.contentView.bounds.maxY > rows.bounds.height { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rows.bounds.height-scroll.bounds.height))); scroll.reflectScrolledClipView(scroll.contentView) }
        let details = entries.map { "\($0.name)，Token \(RelayStyle.count($0.totalTokens))，\(RelayStyle.money($0.amountUSD, precision: 6))。" }.joined(separator: " ")
        setAccessibilityValue("\(snapshot?.sourceLabel ?? "中转站")，总Token \(RelayStyle.count(displayedTotalTokens))，\(visibleStatusText)。\(details)")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
        NSColor(calibratedRed: 0.18, green: 0.15, blue: 0.17, alpha: 0.63).setFill(); bg.fill()
        NSColor.white.withAlphaComponent(0.2).setStroke(); bg.lineWidth = 1; bg.stroke()
        RelayStyle.text("✳", in: NSRect(x: 23, y: 20, width: 25, height: 25), size: 22, color: RelayStyle.ink.withAlphaComponent(0.8))
        RelayStyle.text("中转站", in: NSRect(x: 52, y: 23, width: 110, height: 25), size: 18, weight: .semibold)
        RelayStyle.text(isDemo ? "虚构示例" : "Token 用量", in: NSRect(x: 128, y: 28, width: 140, height: 20), size: 11, color: RelayStyle.muted)
        RelayStyle.text((snapshot?.periodLabel ?? "统计周期未配置") + " · 总 Token", in: NSRect(x: 25, y: 65, width: 310, height: 20), size: 12, color: RelayStyle.muted)
        let hero = displayedTotalTokens.map { RelayStyle.count($0) } ?? "—"
        let width = (hero as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 46, weight: .regular)]).width
        RelayStyle.text(hero, in: NSRect(x: 22, y: 86, width: 314, height: 58), size: max(24, min(46, 46*310/max(310,width))), digits: true)
        let entries = snapshot?.hasReadings == true ? snapshot?.entries : nil
        let input = entries.flatMap { RelayRules.sum($0.map(\.inputTokens)) }, output = entries.flatMap { RelayRules.sum($0.map(\.outputTokens)) }
        let tokenDetail = "输入 " + RelayStyle.count(input) + " · 输出 " + RelayStyle.count(output)
        RelayStyle.text(tokenDetail, in: NSRect(x: 25, y: 143, width: 310, height: 18), size: 10, color: RelayStyle.muted, digits: true)
        RelayStyle.text("调用 " + RelayStyle.count(displayedTotalCalls), in: NSRect(x: 25, y: 166, width: 150, height: 19), size: 11, color: RelayStyle.muted, digits: true)
        RelayStyle.text(RelayStyle.money(displayedTotalUSD, precision: 2), in: NSRect(x: 175, y: 165, width: 160, height: 20), size: 12, digits: true, align: .right)
        rule(189); rule(407)
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "MM/dd HH:mm"
        let captured = snapshot?.capturedAt.map { f.string(from: $0) } ?? "未同步"
        RelayStyle.text(visibleStatusText + " · " + captured, in: NSRect(x: 25, y: 416, width: 310, height: 17), size: 10, color: RelayStyle.muted)
        RelayStyle.text("来源：" + (snapshot?.sourceLabel ?? "中转站") + ((entries?.count ?? 0)>4 ? " · 向下滚动查看更多" : ""), in: NSRect(x: 25, y: 433, width: 310, height: 14), size: 9, color: RelayStyle.muted.withAlphaComponent(0.76))
    }
    private func rule(_ y: CGFloat) { NSColor.white.withAlphaComponent(0.15).setFill(); NSRect(x: 24, y: y, width: 312, height: 0.5).fill() }
}
