import AppKit

extension Notification.Name {
    /// 列表列宽变了（拖动表头分隔线）——表头和所有行都要跟着改
    static let listColumnsChanged = Notification.Name("FolderSync.listColumnsChanged")
}

/// 列表各列宽度：表头和行共用同一份，可拖表头分隔线调整，存进 UserDefaults。
///
/// 之前这些宽度是 `ListHeaderView` 上的 `static let`，表头和行各自引用同一个常量，
/// 所以"能看齐但改不了"。现在抽到这里，改完发通知，表头和可见的行一起更新。
enum ListColumns {

    static let minWidth: CGFloat = 44
    static let leadingInset: CGFloat = 6
    static let iconArea: CGFloat = 30

    private static let key = "listColumnWidths"

    private static var stored: [String: CGFloat] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
            return raw.mapValues { CGFloat($0) }
        }
        set {
            UserDefaults.standard.set(newValue.mapValues { Double($0) }, forKey: key)
        }
    }

    static var date: CGFloat { get { stored["date"] ?? 150 } set { write("date", newValue) } }
    static var size: CGFloat { get { stored["size"] ?? 78 } set { write("size", newValue) } }
    static var kind: CGFloat { get { stored["kind"] ?? 92 } set { write("kind", newValue) } }

    private static func write(_ name: String, _ value: CGFloat) {
        var copy = stored
        let clamped = max(minWidth, value.rounded())
        guard copy[name] != clamped else { return }
        copy[name] = clamped
        stored = copy
        NotificationCenter.default.post(name: .listColumnsChanged, object: nil)
    }
}
