import AppKit

/// 桌面组件式窗口。
///
/// 两个关键点（都是踩出来的）：
/// 1. ~~`.nonactivatingPanel`~~ —— **已经去掉**（点击它不会激活本应用，键盘事件就进不来；
///    详见 AppActivation.swift 的注释）。当初用它是为了"点组件不打扰前台应用"，
///    所以不会顶掉别的应用、也不会把别的窗口压下去。
/// 2. `canBecomeKey = true` —— **必须能成为 key**，否则窗口收不到正常鼠标交互，
///    表现就是"里面的文件选不中、拖不动"。非激活面板不会因此抢走前台。
final class WidgetPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 「点窗口空白处 = 显示桌面（隐藏其他应用）」的回调
    var onBackgroundClick: (() -> Void)?

    static func make(contentRect: NSRect, level: WindowLevelMode) -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: contentRect,
            // **不用 `.nonactivatingPanel`**：那样点窗口不会激活本应用，而键盘事件
            // 只有本应用激活时才送得进来 —— "选中文件按空格"的空格就跑到前台应用去了。
            // 现在点窗口按 AppKit 标准路径激活（配合 AppActivation.toFront() 双保险）。
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false           // 别的应用激活时也不消失
        // 不用 AppKit 自带的背景拖动：它无法把窗口限制在屏幕内
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 320, height: 240)
        panel.animationBehavior = .none
        panel.worksWhenModal = true
        // 组件不成为前台应用，但必须显式接收鼠标移动事件，否则悬停浮层不出现
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        return panel
    }
}
