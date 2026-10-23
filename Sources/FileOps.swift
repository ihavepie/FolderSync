import AppKit

/// 落盘操作：默认复制，按住 Option 移动。同名不覆盖，自动加序号。
enum FileOps {

    struct Result {
        var copied: Int = 0
        var moved: Int = 0
        var skipped: Int = 0
        var errorMessage: String?

        var summary: String {
            var parts: [String] = []
            if copied > 0 { parts.append("复制 \(copied) 项") }
            if moved > 0 { parts.append("移动 \(moved) 项") }
            if skipped > 0 { parts.append("跳过 \(skipped) 项") }
            if parts.isEmpty { parts.append("没有文件被写入") }
            return parts.joined(separator: "，")
        }
    }

    /// Finder 拖拽时按住的修饰键决定语义
    static var wantsMove: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// 同名文件不覆盖，生成 "名字 2.ext"
    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 把外部拖入的 URL 落盘到目标目录
    @discardableResult
    static func ingest(urls: [URL], into directory: URL, move: Bool) -> Result {
        let fm = FileManager.default
        var result = Result()
        var firstError: String?

        for source in urls {
            let sourcePath = source.path
            guard sourcePath != directory.path else { result.skipped += 1; continue }
            // 本来就躺在这个目录里的，别再"复制一份自己"。
            // 从窗口里把文件拖出去又松手在窗口里（或者拖拽只是手抖），都会走到这里，
            // 之前的后果是凭空多出一个 "xxx 2.txt"。这种情况静默忽略，不算错误。
            if source.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL {
                continue
            }
            // 不允许把目录拖进它自己里面
            if directory.path.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/") {
                result.skipped += 1
                continue
            }

            let destination = uniqueDestination(for: source.lastPathComponent, in: directory)
            do {
                if move {
                    try fm.moveItem(at: source, to: destination)
                    result.moved += 1
                } else {
                    try fm.copyItem(at: source, to: destination)
                    result.copied += 1
                }
            } catch {
                result.skipped += 1
                if firstError == nil { firstError = error.localizedDescription }
                NSLog("[FolderSync] ingest failed \(sourcePath): \(error)")
            }
        }

        result.errorMessage = firstError
        return result
    }

    /// 明确用**访达**打开一个文件夹。
    ///
    /// 不能直接用 `NSWorkspace.open(url)`：本应用在 Info.plist 里注册了
    /// `public.folder`（为了支持"用 FolderSync 打开文件夹"），
    /// 于是打开文件夹有可能被路由回自己，表现就是"双击文件夹没反应/不出现访达"。
    /// 指定 Finder.app 就能绕开这个歧义。
    static func openInFinder(_ url: URL) {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: config) { _, error in
            if let error { NSLog("[FolderSync] 用访达打开失败: \(error)") }
            // 光靠 config.activates 不够：本应用是 `.accessory`（后台应用），
            // 系统不会因为"一个后台应用请求打开"就把访达切到前面来 ——
            // 实测双击后前台还是原来的应用，访达窗口开在后面。
            // 这里等窗口建好之后显式激活一次。
            DispatchQueue.main.async {
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: "com.apple.finder")
                    .first?
                    .activate(options: [])   // 只激活访达本身；别把它的所有窗口都提上来
            }
        }
    }

    /// 打开一个条目：**文件夹交给访达**，其它交给系统默认应用。
    ///
    /// 双击组件里的图标、预览浮层里回车，走的都是这里 —— 逻辑只有一份。
    static func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if exists, isDirectory.boolValue, !isPackage {
            openInFinder(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 复制一份（访达的 ⌘D「复制」）：同名不覆盖，生成 "名字 副本.ext"（再冲突就加序号）
    @discardableResult
    static func duplicate(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        var done = 0
        for url in urls {
            let ext = url.pathExtension
            let base = (url.lastPathComponent as NSString).deletingPathExtension
            let candidateName = ext.isEmpty ? "\(base) 副本" : "\(base) 副本.\(ext)"
            let destination = uniqueDestination(for: candidateName, in: url.deletingLastPathComponent())
            do {
                try fm.copyItem(at: url, to: destination)
                done += 1
            } catch {
                NSLog("[FolderSync] 复制失败 \(url.path): \(error)")
            }
        }
        return done
    }

    /// 制作替身（访达的「制作替身」）。
    /// 用 `.suitableForBookmarkFile` 写出来的就是**访达认得的替身**，不是符号链接。
    @discardableResult
    static func makeAlias(_ urls: [URL]) -> Int {
        var done = 0
        for url in urls {
            let ext = url.pathExtension
            let base = (url.lastPathComponent as NSString).deletingPathExtension
            let aliasName = ext.isEmpty ? "\(base) 替身" : "\(base) 替身.\(ext)"
            let destination = uniqueDestination(for: aliasName, in: url.deletingLastPathComponent())
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
                try URL.writeBookmarkData(data, to: destination)
                done += 1
            } catch {
                NSLog("[FolderSync] 制作替身失败 \(url.path): \(error)")
            }
        }
        return done
    }

    /// 压缩成 zip（访达的「压缩」）。
    /// 用 `NSFileCoordinator` 的 `.forUploading` —— 这是公开 API 里唯一能直接产出 zip 的路子，
    /// 它给的是临时目录里的一个 .zip，再搬到原位置旁边。
    @discardableResult
    static func compress(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        var done = 0
        for url in urls {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var produced: URL?
            coordinator.coordinate(readingItemAt: url, options: [.forUploading],
                                   error: &coordinationError) { tempZip in
                let name = url.deletingPathExtension().lastPathComponent + ".zip"
                let destination = uniqueDestination(for: name, in: url.deletingLastPathComponent())
                do {
                    try fm.moveItem(at: tempZip, to: destination)
                    produced = destination
                } catch {
                    NSLog("[FolderSync] 压缩搬运失败: \(error)")
                }
            }
            if let error = coordinationError {
                NSLog("[FolderSync] 压缩失败 \(url.path): \(error)")
            }
            if produced != nil { done += 1 }
        }
        return done
    }

    // MARK: - 标签（访达的「给…添加标签」）

    /// 访达的标签色。名字和色号是访达自己那套：
    /// 扩展属性 `com.apple.metadata:_kMDItemUserTags` 里存的是 `"名字\n色号"` 的数组。
    struct FinderTag {
        let name: String
        let colorIndex: Int
        static let all: [FinderTag] = [
            FinderTag(name: "红色", colorIndex: 6),
            FinderTag(name: "橙色", colorIndex: 7),
            FinderTag(name: "黄色", colorIndex: 5),
            FinderTag(name: "绿色", colorIndex: 2),
            FinderTag(name: "蓝色", colorIndex: 4),
            FinderTag(name: "紫色", colorIndex: 3),
            FinderTag(name: "灰色", colorIndex: 1),
        ]
        var color: NSColor {
            switch colorIndex {
            case 1: return .systemGray
            case 2: return .systemGreen
            case 3: return .systemPurple
            case 4: return .systemBlue
            case 5: return .systemYellow
            case 6: return .systemRed
            default: return .systemOrange
            }
        }
    }

    private static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// 读出某个文件现有的标签（"名字\n色号" 形式）
    static func tags(of url: URL) -> [String] {
        let path = url.path
        let name = tagAttribute
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, 0)
        guard read > 0, let list = try? PropertyListSerialization.propertyList(
            from: Data(buffer), options: [], format: nil) as? [String] else { return [] }
        return list
    }

    /// 给文件加一个标签（保留原有标签）
    ///
    /// 走**系统正规入口** `NSURL.setResourceValue(_:forKey:.tagNamesKey)`：
    /// 它同时更新扩展属性和元数据索引。只写 xattr 的话，实测刚写完立刻查
    /// `mdls -name kMDItemUserTags` 还是 `(null)`（Spotlight 过几秒才跟上），
    /// 而**访达显示标签看的正是元数据** —— 表现就是"点完标签没反应"。
    ///
    /// 同一台机器、同一个盘上实测：
    /// ```
    /// 直接写 xattr     → 立刻 mdls = (null)      ← 旧实现
    /// setResourceValue → 立刻 mdls = ("橙色")     ← 现在
    /// ```
    @discardableResult
    static func addTag(_ tag: FinderTag, to urls: [URL]) -> Int {
        var done = 0
        for url in urls {
            var names = tagNames(of: url)
            if !names.contains(tag.name) { names.append(tag.name) }
            if writeTagNames(names, to: url) { done += 1 }
        }
        return done
    }

    /// 读标签名（不含色号）
    static func tagNames(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// 清掉所有标签
    @discardableResult
    static func clearTags(of urls: [URL]) -> Int {
        var done = 0
        for url in urls where writeTagNames([], to: url) { done += 1 }
        return done
    }

    /// 写标签名（空数组 = 清除）。资源值失败时退回直接写 xattr：
    /// 有些文件系统/网络盘不支持元数据写入，那时候至少 xattr 还能落下去。
    private static func writeTagNames(_ names: [String], to url: URL) -> Bool {
        do {
            try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
            return true
        } catch {
            let raw = names.map { name -> String in
                let color = FinderTag.all.first { $0.name == name }?.colorIndex ?? 0
                return "\(name)\n\(color)"
            }
            return writeTags(raw, to: url)
        }
    }

    private static func writeTags(_ list: [String], to url: URL) -> Bool {
        let path = url.path
        let name = tagAttribute
        if list.isEmpty {
            return removexattr(path, name, 0) == 0
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list,
                                                            format: .binary, options: 0) else { return false }
        let result = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return setxattr(path, name, base, data.count, 0, 0)
        }
        return result == 0
    }

    /// 「显示简介」要展示的信息（自己拼，不依赖访达）
    static func infoText(for url: URL) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .contentTypeKey, .isSymbolicLinkKey, .isPackageKey
        ])
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        lines.append("名称：\(url.lastPathComponent)")
        let kind = isPackage ? "应用程序" : (isDirectory ? "文件夹" : (url.pathExtension.isEmpty ? "文稿" : "\(url.pathExtension.uppercased()) 文稿"))
        lines.append("种类：\(kind)")
        if let size = values?.fileSize, !isDirectory {
            lines.append("大小：\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm"
        if let created = values?.creationDate {
            lines.append("创建：\(formatter.string(from: created))")
        }
        if let modified = values?.contentModificationDate {
            lines.append("修改：\(formatter.string(from: modified))")
        }
        if let readable = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
            lines.append(String(format: "权限：%o", readable.intValue))
        }
        lines.append("位置：\(url.deletingLastPathComponent().path)")
        return lines.joined(separator: "\n")
    }

    /// 把 URL 移到废纸篓（删到废纸篓，可恢复）
    static func moveToTrash(_ urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                NSLog("[FolderSync] trash failed \(url.path): \(error)")
            }
        }
    }
}
