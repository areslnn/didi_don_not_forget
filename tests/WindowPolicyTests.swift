import AppKit
@main struct Tests {
    @MainActor static func main() {
        let _ = NSApplication.shared
        for _ in 0..<2 {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            for pinned in [false, true, false, true, false] {
                WidgetWindowPolicy.apply(to: panel, pinned: pinned)
                precondition(panel.isFloatingPanel == pinned)
                precondition(panel.level == (pinned ? .floating : .normal))
                precondition(panel.collectionBehavior.contains(.fullScreenAuxiliary) == pinned)
                precondition(panel.collectionBehavior.contains(.canJoinAllSpaces) == pinned)
                precondition(panel.collectionBehavior.contains(.fullScreenNone) == !pinned)
                precondition(panel.collectionBehavior.contains(.managed) == !pinned)
            }
        }
        print("Both panels: initial unpinned state and repeated pin/unpin transitions passed.")
    }
}
