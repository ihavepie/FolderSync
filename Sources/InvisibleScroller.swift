import AppKit

/// 什么都不画的滚动条。
///
/// 为什么要它：这是个亚克力组件，系统滚动条是**连轨道一起画**的 ——
/// 在透明卡片上那条浅色轨道就是一块"白框"，而 `NSScroller` 没有公开 API
/// 只去掉轨道、留下滑块。组件上干脆整条都不画。
///
/// 为什么不用 `hasVerticalScroller = false`：**实测不生效**。设成 false 之后：
///
/// ```
/// 纵向滚动条: 显示中（isHidden = false）frame = {{598,0},{16,446}}
/// 把它渲染进位图，数非透明像素 = 2845        ← 照画不误
/// ```
///
/// （滚动条视图依然存在、依然占着右边那条位置，也就依然会画出来。）
///
/// 换成这个类之后同一个测法是 **0 个非透明像素**。
///
/// 滚动能力完全不受影响：滚动条只是个控件，不画它照样能用触控板两指、滚轮、
/// 方向键 / PageUp 滚 —— 只是屏幕上不再出现那条"外来"的条和轨道。
final class InvisibleScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    /// 宽度 0：不这么写的话，一旦内容超出、滚动条"该出现"了，
    /// 滚动视图会按**传统滚动条**给它留 15pt，视口从 642 缩到 627
    /// （实测），右边白空一条。声明宽度为 0 就不会占位。
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                     scrollerStyle: NSScroller.Style) -> CGFloat { 0 }
}
