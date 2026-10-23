import AppKit

/// 悬停浮层里的小圆按钮。
/// 背景画在按钮自己的 layer 上，圆角按实际尺寸算（宽高相等 → 正圆）。
/// 之前用子视图做底、又只约束了 22×22，实测 frame 变成 22×18，
/// 圆角 9 就成了胶囊（看着像椭圆）——所以这里用自检量出来再定做法。
final class OverlayButton: NSButton {

    private var tracking: NSTrackingArea?

    /// 固定边长：定为正方形的关键
    static let side: CGFloat = 24

    static func make(symbol: String, tooltip: String, action: Selector, target: AnyObject) -> OverlayButton {
        let button = OverlayButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        // 用必守优先级把边长钉死，否则 NSButton 的固有尺寸会把高度压成 20
        let w = button.widthAnchor.constraint(equalToConstant: side)
        let h = button.heightAnchor.constraint(equalToConstant: side)
        w.priority = .required
        h.priority = .required
        w.isActive = true
        h.isActive = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = target
        button.action = action
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        return button
    }

    /// 自绘圆形底：取较短边做直径并居中。
    /// 这样即使 NSButton 的固有尺寸让 frame 变成 24×20（实测如此），
    /// 画出来的依然是一个正圆，而不是被压扁的胶囊。
    override func draw(_ dirtyRect: NSRect) {
        // 运行时 AX 量到按钮是 26×26（正方形），这里让圆尽量铺满，留 1pt 边距
        let d = max(14, min(bounds.width, bounds.height) - 2)
        let circle = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)

        NSColor.controlBackgroundColor.withAlphaComponent(hovering ? 0.85 : 0.45).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let border = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        border.stroke()

        super.draw(dirtyRect)
    }

    private var hovering = false

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        contentTintColor = .labelColor
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        contentTintColor = .secondaryLabelColor
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

}
