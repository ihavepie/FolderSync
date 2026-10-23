import AppKit

/// 标签色点。
///
/// 访达是这么显示的：列表里跟在文件名后面一个小圆点，图标上贴在角落里。
/// 颜色来自文件的 Finder 标签（`kMDItemUserTags`），由 `FileItem.tags` 带过来。
///
/// 一排最多画三个（再多就挤了），**右端对齐** —— 贴在图标右上角时右端对齐最稳。
final class TagDotsView: NSView {

    static let maxDots = 3
    static let dotSize: CGFloat = 7
    static let dotGap: CGFloat = 2

    var colors: [NSColor] = [] {
        didSet {
            isHidden = colors.isEmpty
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let n = min(colors.count, Self.maxDots)
        guard n > 0 else { return NSSize(width: 0, height: Self.dotSize) }
        return NSSize(width: CGFloat(n) * Self.dotSize + CGFloat(n - 1) * Self.dotGap,
                      height: Self.dotSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = min(colors.count, Self.maxDots)
        guard n > 0 else { return }
        let size = Self.dotSize
        for index in 0..<n {
            let x = bounds.maxX - CGFloat(index + 1) * size - CGFloat(index) * Self.dotGap
            let rect = NSRect(x: x, y: bounds.midY - size / 2, width: size, height: size)
            colors[index].setFill()
            NSBezierPath(ovalIn: rect).fill()
            // 描一圈很淡的边：黄色这类浅色标签在浅背景上不然看不清
            NSColor.black.withAlphaComponent(0.20).setStroke()
            let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}
