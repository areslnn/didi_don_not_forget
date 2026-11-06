import AppKit

@MainActor
enum WidgetWindowPolicy {
    static func apply(to panel: NSPanel, pinned: Bool) {
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.managed, .fullScreenNone, .fullScreenDisallowsTiling, .ignoresCycle]
    }

    static func show(_ panel: NSPanel, pinned: Bool) {
        apply(to: panel, pinned: pinned)
        if pinned { panel.orderFrontRegardless() }
        else { panel.orderBack(nil) }
    }
}
