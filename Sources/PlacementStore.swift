import AppKit

/// 自由放置的坐标存储：按「文件夹 + 文件名」记住每格位置。
/// 名称变化（改名等）时对应记录会失效，自动回到网格排布，不会错位。
enum PlacementStore {

    private static let key = "freePlacementPositions"

    private static func all() -> [String: [String: [Double]]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: [Double]]]) ?? [:]
    }

    private static func keyFor(_ folder: URL) -> String {
        folder.standardizedFileURL.path
    }

    static func positions(in folder: URL) -> [String: NSPoint] {
        guard let map = all()[keyFor(folder)] else { return [:] }
        var out: [String: NSPoint] = [:]
        for (name, xy) in map where xy.count == 2 {
            out[name] = NSPoint(x: xy[0], y: xy[1])
        }
        return out
    }

    /// 批量写入：一次读改写，避免"每个文件都重写一遍整个字典"
    static func setPositions(_ positions: [String: NSPoint], in folder: URL) {
        guard !positions.isEmpty else { return }
        var root = all()
        let folderKey = keyFor(folder)
        var map = root[folderKey] ?? [:]
        for (name, point) in positions {
            map[name] = [Double(point.x), Double(point.y)]
        }
        root[folderKey] = map
        UserDefaults.standard.set(root, forKey: key)
    }

    static func setPosition(_ point: NSPoint, for name: String, in folder: URL) {
        var root = all()
        let folderKey = keyFor(folder)
        var map = root[folderKey] ?? [:]
        map[name] = [Double(point.x), Double(point.y)]
        root[folderKey] = map
        UserDefaults.standard.set(root, forKey: key)
    }

    // MARK: - 子文件夹小框的位置与尺寸

    private static let panelKey = "folderPanelFrames"

    private static func allPanels() -> [String: [String: [Double]]] {
        (UserDefaults.standard.dictionary(forKey: panelKey) as? [String: [String: [Double]]]) ?? [:]
    }

    /// 面板几何统一存在"主窗口目录"下，键是**嵌套相对路径**
    /// （顶层子文件夹是它的名字，更深的是 "父/子"），这样层级嵌套也能记住。
    static func panelFrames(in root: URL) -> [String: NSRect] {
        guard let map = allPanels()[root.standardizedFileURL.path] else { return [:] }
        var out: [String: NSRect] = [:]
        for (path, v) in map where v.count == 4 {
            out[path] = NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        return out
    }

    static func setPanelFrame(_ rect: NSRect, key: String, in root: URL) {
        var all = allPanels()
        let rootKey = root.standardizedFileURL.path
        var map = all[rootKey] ?? [:]
        map[key] = [Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height)]
        all[rootKey] = map
        UserDefaults.standard.set(all, forKey: panelKey)
    }

    /// 删除某个子树下所有面板几何（重排时用）
    static func clearPanelFrames(in root: URL) {
        var all = allPanels()
        all.removeValue(forKey: root.standardizedFileURL.path)
        UserDefaults.standard.set(all, forKey: panelKey)
    }

    /// 清空某个文件夹的手动排布，回到自动网格
    static func clear(in folder: URL) {
        var root = all()
        root.removeValue(forKey: keyFor(folder))
        UserDefaults.standard.set(root, forKey: key)
    }
}
