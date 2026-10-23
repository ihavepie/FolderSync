import AppKit

/// 单个文件/文件夹的展示模型
struct FileItem {
    let url: URL
    let name: String
    /// 界面上显示的名字：默认**隐藏后缀**（和访达的默认行为一致）。
    /// 注意排序、定位、追踪仍然用完整的 `name`，只有显示用这个。
    var displayName: String
    let isDirectory: Bool
    /// 包（`.app`、`.rtfd`…）：在磁盘上它是目录，但对用户来说是一个"文件"。
    /// 隐藏后缀、双击行为、种类都要按"文件"来办。
    let isPackage: Bool
    let icon: NSImage
    let sizeText: String
    let modified: Date?
    let kindText: String
    /// 穿透显示时，这个文件所在的子文件夹（相对路径）；顶层为空
    let relativeFolder: String
    /// Finder 标签名（`kMDItemUserTags`，只有名字不带色号）
    let tags: [String]

    /// 标签对应的颜色，用来画列表里的色点 / 图标右上角的色点。
    /// 名字认不出来（自定义标签）就给灰色，总比不显示强。
    var tagColors: [NSColor] {
        tags.map { name in
            FileOps.FinderTag.all.first { $0.name == name }?.color ?? .systemGray
        }
    }

    init(url: URL, relativeFolder: String = "") {
        self.url = url
        self.relativeFolder = relativeFolder
        self.name = url.lastPathComponent
        // tagNamesKey 和其余几项**同一次调用**取回来：不多一次系统调用，
        // 所以列大目录时也不会因为"要显示标签"而变慢。
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey, .tagNamesKey,
        ])
        self.isDirectory = values?.isDirectory ?? false
        self.isPackage = values?.isPackage ?? false
        self.modified = values?.contentModificationDate
        self.tags = values?.tagNames ?? []
        // 统一用系统图标：文件夹、图片缩略图、PDF、应用… 全部和 Finder 显示的一样
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
        self.icon.size = NSSize(width: 128, height: 128)   // 高分辨率，缩放显示更清晰

        // 隐藏后缀：对**文件**和**包**（.app 之类）都做，
        // 只有真正的文件夹保留全名（"My.Folder" 这种带点的文件夹名不会被截断）。
        // 访达也是这么分的 —— 所以 Finder 里显示 "FolderSync"，不是 "FolderSync.app"。
        let ext = url.pathExtension
        self.displayName = ((self.isDirectory && !self.isPackage) || ext.isEmpty)
            ? self.name
            : (self.name as NSString).deletingPathExtension

        // 种类（访达列表里那一列）
        if self.isPackage {
            self.kindText = "应用程序"
        } else if self.isDirectory {
            self.kindText = "文件夹"
        } else {
            let lower = ext.lowercased()
            self.kindText = lower.isEmpty ? "文稿" : "\(lower.uppercased()) 文稿"
        }

        if let size = values?.fileSize {
            self.sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            self.sizeText = self.isDirectory ? "文件夹" : ""
        }
    }

    /// 访达的做法：隐藏后缀以后如果**两个条目重名**了（a.txt 和 a.pdf 都变成 a），
    /// 就把这些重名的条目恢复成带后缀的全名，避免"看起来是两个一样的文件"。
    static func resolveDisplayNameConflicts(_ items: inout [FileItem]) {
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            groups[item.displayName, default: []].append(index)
        }
        for (_, indices) in groups where indices.count > 1 {
            for index in indices where items[index].displayName != items[index].name {
                items[index].displayName = items[index].name
            }
        }
    }
}
