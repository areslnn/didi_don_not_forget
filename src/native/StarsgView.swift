import AppKit
import Foundation

/// All amounts are USD; sharePercent is this key's share of the period's USD cost.
/// The source must mark a snapshot live/stale only after retrieving a complete
/// period. A nil/loading/unconnected snapshot deliberately has no numeric totals.
struct StarsgEntry {
    let name: String
    let calls: Int
    let amountUSD: Double
    let sharePercent: Double
}

struct StarsgSnapshot {
    let periodLabel: String
    let capturedAt: Date?
    let sourceLabel: String
    /// Supported states: live, stale, snapshot, loading, unconnected, unavailable.
    let status: String
    let entries: [StarsgEntry]
}

private enum StarsgStyle {
    static let ink = NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.89, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.80, green: 0.78, blue: 0.76, alpha: 0.86)
    static let rowHeight: CGFloat = 50

    static func text(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = ink, digits: Bool = false, align: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    static func calls(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: "en_US"))) }
    static func money(_ n: Double, precision: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = precision
        formatter.maximumFractionDigits = precision
        return "$" + (formatter.string(from: NSNumber(value: n)) ?? "—")
    }
}

@MainActor
private final class StarsgRowsView: NSView {
    var entries: [StarsgEntry] = [] { didSet { needsDisplay = true } }
    var emptyMessage = "尚未连接 Starsg" { didSet { needsDisplay = true } }
    var emptyDetail = "登录后显示该期间的调用与费用" { didSet { needsDisplay = true } }
    var showMenu: ((NSView) -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { showMenu?(self) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if entries.isEmpty {
            StarsgStyle.text(emptyMessage, in: NSRect(x: 0, y: 64, width: bounds.width, height: 24), size: 14, weight: .medium, align: .center)
            StarsgStyle.text(emptyDetail, in: NSRect(x: 0, y: 93, width: bounds.width, height: 22), size: 10, color: StarsgStyle.muted, align: .center)
            return
        }
        for (i, entry) in entries.enumerated() {
            let y = CGFloat(i) * StarsgStyle.rowHeight
            let width = bounds.width - 5
            let amountWidth: CGFloat = 142
            StarsgStyle.text(entry.name.isEmpty ? "未命名 Key" : entry.name,
                             in: NSRect(x: 0, y: y, width: width - amountWidth - 10, height: 20), size: 13, weight: .medium)
            StarsgStyle.text(StarsgStyle.money(entry.amountUSD, precision: 6),
                             in: NSRect(x: width - amountWidth, y: y + 1, width: amountWidth, height: 19), size: 12,
                             weight: .medium, digits: true, align: .right)
            StarsgStyle.text(StarsgStyle.calls(entry.calls) + " 次调用",
                             in: NSRect(x: 0, y: y + 21, width: 145, height: 16), size: 10, color: StarsgStyle.muted, digits: true)
            StarsgStyle.text("费用占比 " + String(format: "%.1f%%", entry.sharePercent),
                             in: NSRect(x: 150, y: y + 21, width: width - 150, height: 16), size: 10,
                             color: StarsgStyle.muted, digits: true, align: .right)
            let bar = NSRect(x: 0, y: y + 40, width: width, height: 2)
            NSColor.white.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            let progress = NSRect(x: 0, y: y + 40, width: width * max(0, min(100, entry.sharePercent)) / 100, height: 2)
            StarsgStyle.ink.withAlphaComponent(0.63).setFill(); NSBezierPath(roundedRect: progress, xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Mount inside the same dark NSVisualEffectView/rounded NSPanel shell as WidgetView.
/// Usage: view.snapshot = snapshot; view.showMenu = { anchor in ... }.
/// Four keys fit at once; NSScrollView retains every additional key without truncation.
@MainActor
final class StarsgView: NSView {
    static let preferredSize = NSSize(width: 360, height: 432)
    var snapshot: StarsgSnapshot? { didSet { updateContents() } }
    var showMenu: ((NSView) -> Void)? { didSet { rows.showMenu = showMenu } }
    private let gear = NSButton()
    private let scroll = NSScrollView()
    private let rows = StarsgRowsView(frame: .zero)
    override var isFlipped: Bool { true }

    private var isValidSnapshot: Bool {
        guard let snapshot, snapshot.status == "live" || snapshot.status == "stale" || snapshot.status == "snapshot" else { return false }
        return snapshot.entries.allSatisfy {
            $0.calls >= 0 && $0.amountUSD.isFinite && $0.amountUSD >= 0 &&
            $0.sharePercent.isFinite && $0.sharePercent >= 0 && $0.sharePercent <= 100
        }
    }
    var displayedTotalUSD: Double? {
        guard isValidSnapshot, let snapshot else { return nil }
        let total = snapshot.entries.reduce(0.0) { $0 + $1.amountUSD }
        return total.isFinite ? total : nil
    }
    var displayedTotalCalls: Int? {
        guard isValidSnapshot, let snapshot else { return nil }
        var total = 0
        for entry in snapshot.entries {
            let addition = total.addingReportingOverflow(entry.calls)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
    private var canShowValues: Bool { displayedTotalUSD != nil && displayedTotalCalls != nil }
    var visibleStatusText: String {
        guard let snapshot else { return "尚未连接 Starsg" }
        switch snapshot.status {
        case "live": return canShowValues ? "已同步" : "数据待核对"
        case "stale": return canShowValues ? "同步暂缓 · 保留最近读数" : "数据待核对"
        case "snapshot": return canShowValues ? "已读取 · 待连接自动更新" : "数据待核对"
        case "loading": return "正在同步 Starsg…"
        case "unconnected": return "尚未连接 Starsg"
        default: return "暂时无法读取 Starsg"
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gear.frame = NSRect(x: 307, y: 18, width: 30, height: 30)
        gear.isBordered = false
        gear.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Starsg 组件设置")
        gear.contentTintColor = StarsgStyle.ink.withAlphaComponent(0.76)
        gear.imagePosition = .imageOnly
        gear.target = self
        gear.action = #selector(openMenu)
        gear.toolTip = "设置与操作；拖动空白处移动组件"
        gear.setAccessibilityLabel("Starsg 组件设置")
        addSubview(gear)
        scroll.frame = NSRect(x: 24, y: 177, width: 312, height: 200)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        rows.frame = NSRect(x: 0, y: 0, width: 312, height: 200)
        scroll.documentView = rows
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Starsg API Key 费用看板")
        updateContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openMenu() { showMenu?(gear) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { showMenu?(self) }
    private func updateContents() {
        let entries = canShowValues ? snapshot?.entries ?? [] : []
        rows.entries = entries
        rows.frame = NSRect(x: 0, y: 0, width: 312, height: max(200, CGFloat(entries.count) * StarsgStyle.rowHeight))
        if canShowValues && entries.isEmpty {
            rows.emptyMessage = "该期间暂无调用"
            rows.emptyDetail = "来源已同步，尚无 API Key 用量记录"
        } else {
            rows.emptyMessage = visibleStatusText
            rows.emptyDetail = snapshot?.status == "loading" ? "正在等待来源返回真实数据" : "连接后显示该期间的调用与费用"
        }
        if scroll.contentView.bounds.maxY > rows.bounds.height {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rows.bounds.height - scroll.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let source = snapshot?.sourceLabel.isEmpty == false ? snapshot!.sourceLabel : "Starsg"
        toolTip = "来源：\(source)。每个 Key 的百分比为费用占比；所有 Key 均可在列表中滚动查看。"
        needsDisplay = true
        if let usd = displayedTotalUSD, let calls = displayedTotalCalls {
            let details = entries.map { "\($0.name)，\($0.calls) 次调用，\(StarsgStyle.money($0.amountUSD, precision: 6))，费用占比 \(String(format: "%.1f", $0.sharePercent))%。" }.joined(separator: " ")
            setAccessibilityValue("\(snapshot?.periodLabel ?? "最近 30 天")总费用 \(StarsgStyle.money(usd, precision: 2))，\(calls) 次调用。\(visibleStatusText)。来源：\(source)。\(details)")
        } else { setAccessibilityValue("\(visibleStatusText)。尚无已确认的费用数据。来源：\(source)。") }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
        NSColor(calibratedRed: 0.18, green: 0.15, blue: 0.17, alpha: 0.63).setFill(); background.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke(); background.lineWidth = 1; background.stroke()
        StarsgStyle.text("✳", in: NSRect(x: 23, y: 20, width: 25, height: 25), size: 22, color: StarsgStyle.ink.withAlphaComponent(0.8))
        StarsgStyle.text("Starsg", in: NSRect(x: 52, y: 23, width: 110, height: 25), size: 18, weight: .semibold)
        StarsgStyle.text("API 用量", in: NSRect(x: 129, y: 28, width: 140, height: 20), size: 11, color: StarsgStyle.muted)
        StarsgStyle.text((snapshot?.periodLabel ?? "最近 30 天") + " · 费用", in: NSRect(x: 25, y: 65, width: 310, height: 20), size: 12, color: StarsgStyle.muted)
        let hero = displayedTotalUSD.map { StarsgStyle.money($0, precision: 2) } ?? "—"
        let heroWidth = (hero as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 48, weight: .regular)]).width
        let heroSize = max(28, min(48, 48 * 310 / max(310, heroWidth)))
        StarsgStyle.text(hero, in: NSRect(x: 22, y: 86, width: 314, height: 62), size: heroSize, digits: true)
        let summary: String
        if let calls = displayedTotalCalls {
            summary = StarsgStyle.calls(calls) + " 次调用 · \(snapshot?.entries.count ?? 0) 个 Key"
        } else { summary = "USD · 等待真实数据" }
        StarsgStyle.text(summary, in: NSRect(x: 25, y: 143, width: 220, height: 19), size: 11, color: StarsgStyle.muted, digits: true)
        if canShowValues && (snapshot?.entries.count ?? 0) > 4 {
            StarsgStyle.text("滚动查看 ↓", in: NSRect(x: 250, y: 143, width: 85, height: 18), size: 10, color: StarsgStyle.muted, align: .right)
        }
        rule(167); rule(386)
        let source = snapshot?.sourceLabel.isEmpty == false ? snapshot!.sourceLabel : "Starsg"
        let captured: String
        if let date = snapshot?.capturedAt {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MM/dd HH:mm"
            captured = formatter.string(from: date)
        } else { captured = "未同步" }
        let statusLine = snapshot?.status == "live" && canShowValues ? "\(captured) 更新 · \(source)" : "\(visibleStatusText) · \(captured)"
        StarsgStyle.text(statusLine, in: NSRect(x: 25, y: 396, width: 310, height: 17), size: 10, color: StarsgStyle.muted)
        if snapshot?.status != "live" || !canShowValues {
            StarsgStyle.text("来源：" + source, in: NSRect(x: 25, y: 412, width: 310, height: 14), size: 9, color: StarsgStyle.muted.withAlphaComponent(0.76))
        }
    }
    private func rule(_ y: CGFloat) {
        NSColor.white.withAlphaComponent(0.15).setFill(); NSRect(x: 24, y: y, width: 312, height: 0.5).fill()
    }
}
