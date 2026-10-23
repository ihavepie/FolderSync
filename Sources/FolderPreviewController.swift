import AppKit

/// 「像 Quick Look 那样的文件夹预览」。
///
/// **为什么自研**：系统 `QLPreviewPanel` 对文件夹只会画一个大图标 + 名称/大小/日期，
/// **不列内容**（访达自己也一样），而且面板外壳零定制（没有 API 往里塞自定义视图）。
/// 所以文件夹的"空格预览"只能自己做；文件仍然交给系统 Quick Look（图片/PDF/Office
/// 那些格式自己渲染不现实）。
///
/// **和新组件窗口的分工**：
///
/// | | 本浮层 | 常驻组件窗口 |
/// |---|---|---|
/// | 生命周期 | 空格/Esc/点外面/父窗口关 → 没了 | 常驻，要显式关 |
/// | 位置 | 不记忆，每次贴父窗口弹 | 按目录记忆（稳定名 autosave） |
/// | 拖动窗口 | 不能拖 | 能拖 |
/// | 往里拖文件 | **不行**（只读来源目录，免得误操作） | 能 |
/// | 拖出/打开/往下钻 | 能 | 能 |
/// | 常用它就… | 点「钉住」→ 变成常驻组件窗口 | — |
final class FolderPreviewController: NSObject {

    /// 目录变了（往下钻 / ⌫ 回上层）时由外部知道，用来做菜单勾选之类
    private(set) var folderURL: URL
    /// 点「钉住」：把当前目录提升成常驻组件窗口（由 AppDelegate 实现）
    var onPin: ((URL) -> Void)?

    private let parentWindow: NSWindow
    private let levelMode: WindowLevelMode
    private var panel: WidgetPanel?
    private var collectionView: FolderCollectionView?
    private var scrollView: NSScrollView?
    private var nameLabel: NSTextField?
    private var pathLabel: NSTextField?
    private var countLabel: NSTextField?
    private var pinButton: NSButton?
    private var watcher: DirectoryWatcher?
    private var items: [FileItem] = []
    private var loadGeneration = 0
    private var clickMonitor: Any?
    private var parentCloseObserver: NSObjectProtocol?

    /// 最初是从哪个目录打开的：⌫ 最多退到这里，不越界
    private let rootURL: URL

    init(folderURL: URL, parent: NSWindow, levelMode: WindowLevelMode) {
        self.folderURL = folderURL
        self.rootURL = folderURL
        self.parentWindow = parent
        self.levelMode = levelMode
        super.init()
        build()
        reload()
        watch()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 组装

    private func build() {
        let parentFrame = parentWindow.frame
        let size = NSSize(width: max(340, parentFrame.width * 0.62),
                          height: max(260, parentFrame.height * 0.62))
        let origin = Self.origin(beside: parentFrame, size: size,
                                 screen: parentWindow.screen ?? NSScreen.main)

        let panel = WidgetPanel.make(contentRect: NSRect(origin: origin, size: size),
                                     level: levelMode)
        // 浮在父窗口之上；不能拖（要拖就「钉住」变成常驻窗口）
        panel.level = parentWindow.level + 1
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        self.panel = panel

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true

        // 顶栏：名字 + 条目数 + 钉住 + 关闭
        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        self.nameLabel = nameLabel
        self.countLabel = countLabel

        // 面包屑：路径缩到"够看就行"（和组件窗口标题同一条规矩）
        let pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        self.pathLabel = pathLabel

        let pin = NSButton(title: "钉住", target: self, action: #selector(pinTapped))
        pin.bezelStyle = .inline
        pin.controlSize = .small
        pin.font = .systemFont(ofSize: 11)
        pin.toolTip = "把这个目录变成常驻组件窗口（位置/大小会被记住，可双向同步）"
        pinButton = pin

        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.bezelStyle = .inline
        close.controlSize = .small
        close.toolTip = "关闭（空格或 Esc 也行）"

        // 内容区
        let collectionView = FolderCollectionView()
        collectionView.acceptsDrops = false        // 只读来源：能拖出，不能拖入
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.urlForIndexPath = { [weak self] indexPath in
            guard let self, self.items.indices.contains(indexPath.item) else { return nil }
            return self.items[indexPath.item].url
        }
        collectionView.urlsForIndexPaths = { [weak self] paths in
            guard let self else { return [] }
            return paths.compactMap { self.items.indices.contains($0.item) ? self.items[$0.item].url : nil }
        }
        collectionView.onDoubleClick = { [weak self] indexPath in self?.activate(indexPath) }
        collectionView.onOpen = { [weak self] in
            guard let self else { return }
            for path in self.collectionView?.selectionIndexPaths ?? [] { self.activate(path) }
        }
        collectionView.onQuickLook = { [weak self] in self?.closeTapped() }   // 空格 = 收掉
        collectionView.onEscape = { [weak self] in self?.closeTapped() }      // Esc = 收掉
        collectionView.onBack = { [weak self] in self?.goToParent() }         // ⌫ = 回上一层（预览里没有废纸篓）
        collectionView.menuProvider = { [weak self] indexPath, view in self?.menu(for: indexPath, in: view) }
        // 图标尺寸跟随全局设置，间距/边距全走 GridMetrics，和组件窗口一致
        let layout = IconLayout()
        layout.iconSide = ViewSettings.iconSize
        layout.itemSize = GridMetrics.itemSize(iconSide: ViewSettings.iconSize)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        self.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = InvisibleScroller()
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScroller = InvisibleScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        self.scrollView = scrollView

        // 注意别把 backdrop 自己也放进这个数组 —— 往自己身上 addSubview 会让 AppKit 卡死
        for v in [nameLabel, countLabel, pathLabel, pin, close, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(v)
        }
        panel.contentView = backdrop

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),

            countLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -8),

            // 面包屑在名字下面一行
            pathLabel.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -8),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            pin.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            pin.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -GridMetrics.bottomReserve),
        ])

        // 空格/Esc/点外面：都收掉
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.window !== panel { self.close() }
            return event
        }
        // 切到别的应用（用户点了别处）也收掉 —— 只靠本地鼠标监听抓不到这一下
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.close() }
    }

    /// 贴在父窗口旁边：右侧优先，放不下换左侧，再不行放下方；永远夹在屏幕里
    private static func origin(beside parent: NSRect, size: NSSize, screen: NSScreen?) -> NSPoint {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12
        var x = parent.maxX + gap
        if x + size.width > visible.maxX { x = parent.minX - gap - size.width }
        if x < visible.minX { x = parent.midX - size.width / 2 }
        var y = parent.maxY - size.height
        if y + size.height > visible.maxY { y = visible.maxY - size.height }
        if y < visible.minY { y = visible.minY }
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        return NSPoint(x: x, y: y)
    }

    // MARK: - 显示 / 关闭

    func show() {
        guard let panel else { return }
        // 成为父窗口的子窗口：跟着父窗口一起移动，父窗口关掉它也没了
        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
            parentCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: parentWindow, queue: .main
            ) { [weak self] _ in self?.close() }
        }
        AppActivation.toFront()   // 不然键盘（空格/Esc/方向键）进不来（旧 API 在 14+ 是空操作）
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(collectionView)
    }

    @objc private func closeTapped() { close() }

    func close() {
        watcher?.stop()
        watcher = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }

    @objc private func pinTapped() {
        let url = folderURL
        onPin?(url)
        close()
    }

    // MARK: - 目录

    private func watch() {
        watcher?.stop()
        watcher = DirectoryWatcher(path: folderURL.path) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        watcher?.start()
    }

    private func bind(_ url: URL) {
        folderURL = url
        reload()
        watch()
    }

    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let directory = folderURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let flat = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles])) ?? []
            let items = flat.map { FileItem(url: $0) }.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.items = items
                self.collectionView?.reloadData()
                self.nameLabel?.stringValue = directory.lastPathComponent
                self.countLabel?.stringValue = items.isEmpty ? "空文件夹" : "\(items.count) 项"
                self.pathLabel?.stringValue = FolderWindowController.abbreviatedPath(directory)
                self.pinButton?.isEnabled = true
            }
        }
    }

    private func activate(_ indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        let item = items[indexPath.item]
        // 文件夹：**往下钻**（预览里层层看，比系统 Quick Look 只能看一层实用）
        if item.isDirectory && !item.isPackage {
            bind(item.url)
        } else {
            FileOps.open(item.url)
        }
    }

    /// 右键菜单：预览是"只读地看"，所以只给不会改文件的那几项
    private func menu(for indexPath: IndexPath, in view: NSView) -> NSMenu? {
        guard items.indices.contains(indexPath.item) else { return nil }
        // 右键落在没选中的条目上时，先把它选中
        if let cv = collectionView, !cv.selectionIndexPaths.contains(indexPath) {
            cv.selectionIndexPaths = [indexPath]
        }
        let item = items[indexPath.item]
        let menu = NSMenu()

        let header = NSMenuItem(title: item.displayName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let open = NSMenuItem(title: item.isDirectory ? "在新组件窗口中打开" : "打开",
                              action: #selector(openSelected), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealSelected), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let copyPath = NSMenuItem(title: "拷贝路径", action: #selector(copySelectedPath), keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)

        menu.addItem(.separator())
        let pin = NSMenuItem(title: "钉住此文件夹", action: #selector(pinTapped), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
        return menu
    }

    private var selectedItems: [FileItem] {
        (collectionView?.selectionIndexPaths ?? []).compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
    }

    @objc private func openSelected() {
        let picked = selectedItems
        guard let first = picked.first else { return }
        if first.isDirectory && !first.isPackage {
            bind(first.url)                       // 文件夹：往下钻
        } else {
            for item in picked where !item.isDirectory { FileOps.open(item.url) }
        }
    }

    @objc private func revealSelected() {
        let urls = selectedItems.map { $0.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func copySelectedPath() {
        let text = selectedItems.map { $0.url.path }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func goToParent() {
        let parent = folderURL.deletingLastPathComponent().standardizedFileURL
        // 最多退到最初打开的那个目录的**卷根**，不越出这块盘
        let root = FolderWindowController.volumeRoot(of: rootURL)   // 卷根路径（String）
        guard parent.path != folderURL.path, parent.path.hasPrefix(root) else {
            NSSound.beep()
            return
        }
        bind(parent)
    }
}

// MARK: - 数据源

extension FolderPreviewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        // **直接构造**，不走 `makeItem` 的复用。
        // 这里有个没查清的怪事：同一个类、同一个 identifier，在组件窗口里
        // `makeItem` 正常，在预览浮层里却报 "must register a nib or a class"。
        // 预览里条目本来就少，不复用毫无损失，就不为它继续刨了。
        let cell = FileItemView()
        if items.indices.contains(indexPath.item) {
            cell.configure(with: items[indexPath.item], marked: false, showFolder: false)
        }
        return cell
    }
}
