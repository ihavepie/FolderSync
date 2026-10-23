import AppKit

/// 把本应用切到前台（**唯一的正确写法**）。
///
/// 为什么单独抽出来：`NSApp.activate(ignoringOtherApps: true)` 在 **macOS 14+ 是空操作**，
/// 编译器只会给一句很容易被忽略的警告：
///
/// ```
/// 'activateIgnoringOtherApps' was deprecated in macOS 14.0:
/// ignoringOtherApps is deprecated in macOS 14 and will have no effect.
/// ```
///
/// 后果很隐蔽：组件窗口是 `.nonactivatingPanel`（点它不激活应用），我们以为
/// "点一下会激活自己、空格就能进来"，实际什么都没发生 —— 于是"选中文件按空格"
/// 的空格跑到了前台应用那边（实测跑到浏览器里打了个空格）。
/// 预览浮层的空格/Esc/⌫ 也是同一个原因收不到。
///
/// macOS 14 起换成无参的 `NSApp.activate()`；更老系统仍用旧 API。
enum AppActivation {
    static func toFront() {
        if NSApp.isActive { return }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
