import AppKit

/// 顶层容器：左上原点坐标 + 悬停感知（用来淡入淡出浮层控件）
final class CanvasView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

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

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    /// 右键空白处弹出同样的功能菜单
    var onContextMenu: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        // 落在网格单元上的右键由 collectionView 自己处理
        onContextMenu?(event)
    }

}
