import AppKit

enum MenuBarIcon {
    // A small two-row panel identifies the quota window. Both rows are fixed
    // marks, so the icon never suggests a measured percentage or sync state.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.5, width: 14.5, height: 13),
                xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()

            for y: CGFloat in [6.5, 11.5] {
                NSBezierPath(ovalIn: NSRect(x: 4, y: y - 1, width: 2, height: 2)).fill()
                let row = NSBezierPath()
                row.lineWidth = 1.5
                row.lineCapStyle = .round
                row.move(to: NSPoint(x: 8, y: y))
                row.line(to: NSPoint(x: 13, y: y))
                row.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex 与 Claude Code 订阅额度"
        return image
    }()

    static func configure(_ button: NSStatusBarButton) {
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        button.toolTip = "Token Monitor · Codex 与 Claude Code 订阅额度\n点击打开菜单，管理小窗口或立即同步"
        button.setAccessibilityLabel("Token Monitor，Codex 与 Claude Code 订阅额度")
        button.setAccessibilityHelp("点击打开菜单，管理额度小窗口或立即同步")
    }
}
