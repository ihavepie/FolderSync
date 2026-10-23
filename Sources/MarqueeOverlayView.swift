import AppKit

/// 框选矩形。对齐访达/桌面的观感：
/// 系统强调色描边 + 很淡的同色填充（访达用的是强调色，不是灰）。
/// 单独一个视图，缩小/结束时不会有残留。
final class MarqueeOverlayView: NSView {

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 整块重画，避免任何残影
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.14).setFill()
        bounds.fill()

        // 1px 描边画在像素中心，保证清晰不发虚
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        accent.withAlphaComponent(0.9).setStroke()
        border.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 不拦截鼠标
}
