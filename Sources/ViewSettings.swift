import AppKit

/// 视图显示方式
enum ViewMode: String, CaseIterable {
    case icon
    case list

    var title: String {
        switch self {
        case .icon: return "图标"
        case .list: return "列表"
        }
    }

    var symbolName: String {
        switch self {
        case .icon: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// 排序方式（对齐访达的"整理方式"）
enum SortMode: String, CaseIterable {
    // 顺序照访达的「排序方式」菜单：名称 / 种类 / 修改日期 / 大小
    case name
    case kind
    case dateModified
    case size

    var title: String {
        switch self {
        case .name: return "名称"
        case .dateModified: return "修改日期"
        case .size: return "大小"
        case .kind: return "种类"
        }
    }
}

/// 整理方式（对齐访达图标视图的「整理方式」菜单）
enum ArrangeMode: String, CaseIterable {
    // 顺序照访达的「整理方式」菜单：无 / 贴靠网格 / 按名称 / 按种类 / 按修改日期 / 按大小
    case none            // 无：位置随便摆
    case snapToGrid      // 贴靠网格
    case byName
    case byKind
    case byDate
    case bySize

    var title: String {
        switch self {
        case .none: return "无"
        case .snapToGrid: return "贴靠网格"
        case .byName: return "按名称"
        case .byKind: return "按种类"
        case .byDate: return "按修改日期"
        case .bySize: return "按大小"
        }
    }

    /// 位置是不是"由摆放决定"的（访达里对应 无 / 贴靠网格）
    var isFree: Bool { self == .none || self == .snapToGrid }

    /// 对应的排序键；无 / 贴靠网格 时顺序由摆放决定，返回 nil
    var sortMode: SortMode? {
        switch self {
        case .none, .snapToGrid: return nil
        case .byName: return .name
        case .byDate: return .dateModified
        case .bySize: return .size
        case .byKind: return .kind
        }
    }
}

/// 视图偏好：图标大小 / 显示方式 / 整理方式 / 排序
/// 存在 UserDefaults 里，所有窗口共享，改一个全都跟着变（和访达一致）
struct ViewSettings {

    private enum Key {
        static let iconSize = "viewIconSize"
        static let mode = "viewMode"
        static let sort = "sortMode"
        static let freePlacement = "freePlacement"
        static let arrange = "arrangeMode"
        static let windowSnap = "windowSnap"
    }

    /// 自检模式：只在内存里改，不写回用户偏好。
    /// （自检为了排除偏好干扰会复位显示方式等开关，不能让它把用户的设置改掉）
    static var ephemeral = false
    private static var overrides: [String: Any] = [:]

    private static func put(_ value: Any, _ key: String) {
        if ephemeral { overrides[key] = value } else { UserDefaults.standard.set(value, forKey: key) }
    }

    private static func raw(_ key: String) -> Any? {
        overrides[key] ?? UserDefaults.standard.object(forKey: key)
    }

    /// 图标边长（访达的滑块范围大致 16…128，这里取更好用的区间）
    static let minIconSize: CGFloat = 32
    static let maxIconSize: CGFloat = 128

    static var iconSize: CGFloat {
        get {
            let v = (raw(Key.iconSize) as? Double) ?? 0
            return v <= 0 ? 64 : min(max(CGFloat(v), minIconSize), maxIconSize)
        }
        set { put(Double(newValue), Key.iconSize) }
    }

    static var mode: ViewMode {
        get { ViewMode(rawValue: (raw(Key.mode) as? String) ?? "") ?? .icon }
        set { put(newValue.rawValue, Key.mode) }
    }

    static var sort: SortMode {
        get { SortMode(rawValue: (raw(Key.sort) as? String) ?? "") ?? .name }
        set { put(newValue.rawValue, Key.sort) }
    }

    /// 自由放置：按用户拖到哪就放哪（访达的"无"整理方式）
    /// 整理方式。老偏好只有 freePlacement + sortMode，这里做一次兼容推导
    static var arrange: ArrangeMode {
        get {
            if let m = ArrangeMode(rawValue: (raw(Key.arrange) as? String) ?? "") { return m }
            if (raw(Key.freePlacement) as? Bool) ?? false { return .none }
            switch sort {
            case .name: return .byName
            case .dateModified: return .byDate
            case .size: return .bySize
            case .kind: return .byKind
            }
        }
        set { put(newValue.rawValue, Key.arrange) }
    }

    /// 位置是否自由摆放（= 整理方式为 无 / 贴靠网格）
    static var freePlacement: Bool {
        get { arrange.isFree }
        set { arrange = newValue ? .none : .byName }
    }

    /// 图标间距**不再是一个设置项**：它跟着图标大小算（`GridMetrics.clearance`）。
    /// 曾经的 `gridSpacing` / `iconSpacing` 两个键就此作废（留在 plist 里也没人读了），
    /// 底部滑块和状态栏的「图标间距 ▸」也一并删掉。

    /// 拖动窗口时吸附：贴屏幕边缘 + 对齐桌面网格（默认开）
    static var windowSnap: Bool {
        get { (raw(Key.windowSnap) as? Bool) ?? true }
        set { put(newValue, Key.windowSnap) }
    }

    /// 吸附网格步长
    static let snapGrid: CGFloat = 20
    /// 触发边缘吸附的距离
    static let snapTolerance: CGFloat = 12
}
