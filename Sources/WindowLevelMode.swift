import AppKit

/// 窗口"待在哪一层"
enum WindowLevelMode: String, CaseIterable {
    /// 钉死在桌面上：桌面图标之上、普通窗口之下。点桌面、切应用都留在原地
    case desktop
    /// 浮在最上层，始终可见
    case floating
    /// 普通窗口（想临时当常规窗口用时）
    case normal

    var title: String {
        switch self {
        case .desktop: return "钉在桌面上"
        case .floating: return "浮动在最上层"
        case .normal: return "普通窗口"
        }
    }

    var symbolName: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .floating: return "pin"
        case .normal: return "macwindow"
        }
    }

    func apply(to window: NSWindow) {
        switch self {
        case .desktop:
            // 层级要夹在两个东西之间（实测得出，写错就会"点不动"）：
            //   下方：desktopWindow —— 点桌面 / "显示桌面"时窗口会被推到的层
            //   上方：desktopIconWindow —— 访达画桌面图标的那一层
            // 必须**高于桌面图标层**：否则访达那个画桌面图标的全屏窗口会盖在组件上面，
            // 把鼠标事件全部吃掉 —— 表现就是"文件选不中、拖不动"（实测踩到过）。
            // 所以取 desktopIconWindow + 1：在桌面图标之上、普通窗口之下。
            let desktopIcons = Int(CGWindowLevelForKey(.desktopIconWindow))
            window.level = NSWindow.Level(rawValue: desktopIcons + 1)
            // canJoinAllSpaces：切换 Space 也跟着走
            // stationary：Mission Control / 显示桌面时不动
            // ignoresCycle：⌘` 循环不到它
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.hidesOnDeactivate = false
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
        case .normal:
            window.level = .normal
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.hidesOnDeactivate = false
        }
    }
}
