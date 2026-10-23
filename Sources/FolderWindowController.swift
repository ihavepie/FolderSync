import AppKit
import Quartz
import ApplicationServices

final class FolderWindowController: NSWindowController {

    private(set) var folderURL: URL
    private(set) var levelMode: WindowLevelMode = .desktop

    private var canvas: CanvasView!
    private var collectionView: FolderCollectionView!
    private var scrollView: NSScrollView!
    private var overlay: NSView!
    private var emptyIconView: NSImageView!
    private var emptyLabel: NSTextField!
    private var statusDot: NSView!
    private var grip: NSView!
    private var nameLabel: NSTextField!
    private var sizeSlider: NSSlider!
    private var viewModeItem: NSMenuItem?
    private var listHeader: ListHeaderView?
    /// 文件夹的"Quick Look 式"预览浮层（系统 QL 对文件夹只画大图标、不列内容，所以自研）
    private var folderPreview: FolderPreviewController?
    /// 浮层上点「钉住」：把这个目录提升成常驻组件窗口（由 AppDelegate 实现）
    var onOpenFolderPermanently: ((URL) -> Void)?
    /// 列表模式的内容底板：亚克力太透，直接叠字读不清，加一层压暗的底
    private var listBackdrop: NSVisualEffectView?
    /// 网格区域的底部锚点（滚动视图的底）
    private var gridBottomAnchor: NSLayoutYAxisAnchor {
        scrollView.bottomAnchor
    }
    private var scrollViewTopConstraint: NSLayoutConstraint?
    private var scrollLeadingConstraint: NSLayoutConstraint?
    private var scrollTrailingConstraint: NSLayoutConstraint?
    private var arrangeItems: [NSMenuItem] = []
    private var sortItems: [NSMenuItem] = []
    /// 列宽变化通知的 token（关窗时移除）
    private var columnObserver: Any?
    /// 上一次"显示桌面"的时间，用来做防抖（见 installBackgroundDrag 的 mouseUp）
    private var lastDesktopToggle = Date.distantPast

    private var watcher: DirectoryWatcher?
    private var items: [FileItem] = []
    private var currentItemWidth: CGFloat = 104
    private var currentItemHeight: CGFloat = 116

    private var overlayVisible = false

    var onClose: (() -> Void)?
    var onLevelModeChanged: ((WindowLevelMode) -> Void)?
    /// ⌘N：再开一个窗口（由 AppDelegate 提供实现）
    var onOpenAnotherWindow: (() -> Void)?

    /// 背景拖动用的临时监听（自己算位置才能把窗口限制在屏幕内）
    private var dragMonitor: Any?
    private var isDraggingWindow = false
    /// 窗口当前是不是"有焦点"（用来决定选中色深/浅）
    private var focusActive = true
    /// 上一次看到的前台应用，用来发现"前台换人了"
    private var lastFrontmostPID: pid_t?
    private var focusTimer: Timer?
    /// 监听"点在别的应用上"——这是最直接的失焦证据
    private var globalClickMonitor: Any?
    /// 出现/消失动画进行中，别让 resize 之类把动画打断
    private var isAnimatingFrame = false
    private var dragMoved = false
    /// 这次按下是否落在空白处（单击松手时用它决定是否显示桌面）
    private var pendingBackgroundClick = false
    /// 拖动中的自由位置（未吸附），松手时用它算吸附目标
    private var lastDragOrigin: CGPoint?
    private var dragGrabOffset = CGPoint.zero

    /// 顶部把手条高度：这条区域内拖动 = 移动窗口
    private let dragHandleHeight: CGFloat = 26

    /// 判断某个窗口内坐标是否落在顶部把手条里
    private func isInDragHandle(_ pointInWindow: CGPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let inContent = contentView.convert(pointInWindow, from: nil)
        // contentView 是翻转坐标（左上原点），所以"顶部"是 y 从 0 到把手高度
        return inContent.y >= 0 && inContent.y <= dragHandleHeight
    }

    private let itemHeight: CGFloat = 116

    /// 同一目录第几次开窗（用于窗口位置自动保存）
    private static var openCounts: [String: Int] = [:]

    /// 自动保存名：目录 + 序号。
    /// 第一个窗口沿用固定名字（重启后位置能恢复），重复开窗各用各的名字，
    /// 这样既不会互相覆盖位置，也不丢位置记忆。
    ///
    /// 名字里**不能用 `String.hashValue`** —— Swift 的字符串哈希每个进程随机加盐，
    /// 同一个目录每次启动算出来的名字都不一样，`setFrameAutosaveName` 等于每次换名字，
    /// 于是窗口大小/位置**从来没被恢复过**（拉好的窗口一重启就回到默认 640x460）。
    /// 换成 FNV-1a：跨进程稳定。
    private static func autosaveName(for folder: URL) -> String {
        let key = folder.standardizedFileURL.path
        let index = openCounts[key, default: 0]
        openCounts[key] = index + 1
        let stable = stableHash(key)
        return index == 0 ? "FolderSyncWindow-\(stable)" : "FolderSyncWindow-\(stable)-dup\(index)"
    }

    /// FNV-1a 64 位：稳定、无依赖，只用来做窗口自动保存名
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - 生命周期

    init(folderURL: URL, levelMode: WindowLevelMode) {
        self.folderURL = folderURL
        self.levelMode = levelMode

        let window = WidgetPanel.make(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), level: levelMode)
        // 标题显示**路径**而不是最后一段名字：
        // 同时开好几个组件时，"Desktop"这种名字看不出到底是哪个目录。
        window.title = Self.abbreviatedPath(folderURL)

        super.init(window: window)
        buildUI()
        // 自动保存名**必须在 super.init 之后**设。
        //
        // `NSWindowController` 在 `super.init(window:)` 里会把它自己的
        // `windowFrameAutosaveName`（默认是空字符串）盖到窗口上 —— 实测：
        //   ① super 之前设好 → 名字=FolderSyncWindow-…
        //   ② super 之后读回来 → 名字=（空）
        //   ④ super 之后再设一次 → 名字稳住，之后 applyLevelMode / 布局都不再被清
        // 名字被清掉就等于没有 autosave（虽然 `setFrameAutosaveName` 返回的是 true），
        // 窗口大小/位置一个都存不下来。
        window.setFrameAutosaveName(Self.autosaveName(for: folderURL))
        applyLevelMode(levelMode)
        bindFolder(folderURL)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { watcher?.stop() }

    // MARK: - 界面：只有内容 + 一层悬停浮层

    private func buildUI() {
        guard let window else { return }

        canvas = CanvasView()
        // 注意：这个视图随后会被设为 window.contentView。
        // 如果这里关掉 autoresizing，AppKit 不会自动把它 pin 满窗口，
        // 而它的 frame 还是 0 —— 窗口会直接塌成 48pt 高（实测踩到过）。
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.autoresizingMask = [.width, .height]
        canvas.onHoverChanged = { [weak self] inside in
            self?.setOverlayVisible(inside, animated: true)
        }
        canvas.onContextMenu = { [weak self] _ in
            self?.showMoreMenu()
        }

        // 亚克力/半透明底板
        let backdrop = NSVisualEffectView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true

        // 网格铺满
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: currentItemWidth, height: itemHeight)
        _ = layout
        // 间距统一走 GridMetrics（和图标布局、格子内部共用一套数字）。
        // 这里的间距跟着图标大小走，所以要把 iconSide 传进去。
        layout.minimumInteritemSpacing = GridMetrics.itemSpacing(iconSide: ViewSettings.iconSize)
        layout.minimumLineSpacing = GridMetrics.lineSpacing(iconSide: ViewSettings.iconSize)
        layout.sectionInset = NSEdgeInsets(top: GridMetrics.top, left: GridMetrics.edge,
                                           bottom: GridMetrics.edge, right: GridMetrics.edge)

        collectionView = FolderCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(FileItemView.self, forItemWithIdentifier: FileItemView.identifier)
        collectionView.register(FileRowView.self, forItemWithIdentifier: FileRowView.identifier)

        collectionView.onDrop = { [weak self] urls, move in self?.handleDrop(urls: urls, move: move) }
        collectionView.onDoubleClick = { [weak self] indexPath in self?.activate(indexPath) }
        collectionView.onTrash = { [weak self] in self?.trashSelection() }
        collectionView.onOpen = { [weak self] in self?.openSelection() }
        collectionView.onQuickLook = { [weak self] in self?.toggleQuickLookForSelection() }
        collectionView.menuProvider = { [weak self] indexPath, view in self?.menu(for: indexPath, in: view) }
        collectionView.urlForIndexPath = { [weak self] indexPath in
            // 索引必须和网格显示的内容是同一份，否则右键/拖拽会作用到错的条目上。
            guard let self else { return nil }
            let source = self.items
            guard source.indices.contains(indexPath.item) else { return nil }
            return source[indexPath.item].url
        }
        collectionView.onMoveItem = { [weak self] indexPath, origin in
            self?.handleInternalMove(indexPath, to: origin)
        }
        collectionView.onDragWillBegin = { [weak self] in
            self?.freezeFreePlacementPositions()
        }
        // 列宽（拖表头分隔线）变了：表头 + 当前可见的行一起改，不用 reloadData
        columnObserver = NotificationCenter.default.addObserver(
            forName: .listColumnsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, ViewSettings.mode == .list else { return }
            self.listHeader?.applyColumnWidths()
            for case let row as FileRowView in self.collectionView.visibleItems() {
                row.applyColumnWidths()
            }
        }
        collectionView.urlsForIndexPaths = { [weak self] indexPaths in
            guard let self else { return [] }
            let source = self.items
            return indexPaths.compactMap { source.indices.contains($0.item) ? source[$0.item].url : nil }
        }

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        // **不画滚动条**：系统滚动条连轨道一起画，在透明卡片上就是一块"白框"，
        // 而 NSScroller 没有公开 API 只去掉轨道 —— 组件上整条都不画。
        // 注意 `hasVerticalScroller = false` **不够**（实测滚动条视图照样存在、
        // 照样画 2845 个非透明像素），所以换成自己那个什么都不画的 NSScroller。
        // 滚动能力不受影响：触控板/滚轮/方向键照旧。
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = InvisibleScroller()
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScroller = InvisibleScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .default
        scrollView.borderType = .noBorder
        // 关键：clip view 自己也会画一层白底，拖动胶囊时就会露出白条
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // 内容没超出时不要有回弹：触控板两指一划，格子跟着上下弹一下很晃眼。
        // .none 只关掉"橡皮筋"，真超出一屏时该滚还是能滚。
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        // 空状态
        let empty = NSView()
        empty.translatesAutoresizingMaskIntoConstraints = false
        emptyIconView = NSImageView()
        emptyIconView.translatesAutoresizingMaskIntoConstraints = false
        emptyIconView.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        emptyIconView.contentTintColor = .tertiaryLabelColor
        emptyIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        emptyLabel = NSTextField(labelWithString: "拖文件进来，或往这个文件夹里放东西")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 11.5)
        emptyLabel.textColor = .tertiaryLabelColor
        // 没权限的时候这里要写两三行字（去哪儿开权限），所以允许换行
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.alignment = .center
        empty.addSubview(emptyIconView)
        empty.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyIconView.topAnchor.constraint(equalTo: empty.topAnchor),
            emptyIconView.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: emptyIconView.bottomAnchor, constant: 8),
            emptyLabel.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            emptyLabel.bottomAnchor.constraint(equalTo: empty.bottomAnchor),
        ])

        // 悬停浮层：所有功能都收在这里，平时完全不可见
        overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.alphaValue = 0
        overlay.isHidden = true

        // 只留一个按钮，所有功能收进它的菜单
        let more = OverlayButton.make(symbol: "ellipsis", tooltip: "菜单：换文件夹 / 层级 / 关闭…",
                                      action: #selector(showMoreMenu), target: self)

        // 顶部中间的抓取条：提示"这里可以拖动这个组件"
        grip = NSView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.wantsLayer = true
        grip.layer?.cornerRadius = 2.5
        grip.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor

        // 左上角：当前文件夹的路径，低调常驻
        nameLabel = NSTextField(labelWithString: "")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        // 路径可能很长：宁可把标题截断，也不能让它把窗口撑宽
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 底部中间的图标大小滑块（只在图标视图下显示，和访达一样）
        sizeSlider = NSSlider(value: Double(ViewSettings.iconSize),
                              minValue: Double(ViewSettings.minIconSize),
                              maxValue: Double(ViewSettings.maxIconSize),
                              target: self, action: #selector(iconSizeChanged(_:)))
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.isContinuous = true
        sizeSlider.controlSize = .small
        sizeSlider.toolTip = "调整图标大小"
        sizeSlider.isHidden = ViewSettings.mode != .icon

        // 底部中间只留「图标大小」一根滑块。
        //
        // 原来旁边还有一根「网格间距」滑块，去掉了：间距现在跟着图标大小算
        // （GridMetrics.clearance），左右恒等于上下，没有要调的档位。

        // 右下角只留一个小状态点
        statusDot = NSView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 2.5

        overlay.addSubview(more)

        // 列表内容底板：跟随面板材质，但更实一点
        let listBackdrop = NSVisualEffectView()
        listBackdrop.translatesAutoresizingMaskIntoConstraints = false
        listBackdrop.material = .contentBackground
        listBackdrop.blendingMode = .withinWindow
        listBackdrop.state = .active
        listBackdrop.wantsLayer = true
        listBackdrop.layer?.cornerRadius = 6
        listBackdrop.layer?.masksToBounds = true
        listBackdrop.isHidden = (ViewSettings.mode != .list)
        self.listBackdrop = listBackdrop

        canvas.addSubview(backdrop)
        canvas.addSubview(listBackdrop)
        canvas.addSubview(scrollView)
        canvas.addSubview(empty)
        canvas.addSubview(overlay)
        canvas.addSubview(grip)
        canvas.addSubview(nameLabel)
        canvas.addSubview(sizeSlider)
        canvas.addSubview(statusDot)
        window.contentView = canvas

        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: canvas.topAnchor, constant: dragHandleHeight)
        scrollLeadingConstraint = scrollView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor)
        scrollTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor)
        NSLayoutConstraint.activate([
            scrollViewTopConstraint!,
            backdrop.topAnchor.constraint(equalTo: canvas.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            // 整块列表底：从抓取条下面一直到窗口底部，表头和表体共用它，
            // 这样看起来是"一整个表格"，而不是表头一条、表体一条。
            listBackdrop.topAnchor.constraint(equalTo: canvas.topAnchor, constant: dragHandleHeight),
            listBackdrop.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 8),
            listBackdrop.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -8),
            listBackdrop.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -8),

            scrollLeadingConstraint!,
            scrollTrailingConstraint!,
            scrollView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),

            overlay.topAnchor.constraint(equalTo: canvas.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            // 只有右上角一个按钮
            more.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 6),
            more.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -9),

            grip.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 9),
            grip.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            grip.widthAnchor.constraint(equalToConstant: 46),
            grip.heightAnchor.constraint(equalToConstant: 5),

            // 标题放到左上角（顶部把手条内），字号加大
            nameLabel.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -10),

            sizeSlider.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            sizeSlider.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -4),
            sizeSlider.widthAnchor.constraint(equalToConstant: 120),

            statusDot.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -9),
            statusDot.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -9),
            statusDot.widthAnchor.constraint(equalToConstant: 5),
            statusDot.heightAnchor.constraint(equalToConstant: 5),
        ])

        window.delegate = self
        applyLayout()
        installBackgroundDrag()
        observeFocusChanges()
    }

    /// 这个点算不算"组件上的空白处"（= 既不在文件格上，也不在按钮/滑块这类控件上）。
    ///
    /// 判定要精确：太粗的话点文件也会触发"显示桌面"（访达乱跳）；
    /// 干脆不判又变成点空白没反应。
    private func isBackgroundClick(at pointInWindow: CGPoint) -> Bool {
        guard let window else { return false }
        let local = collectionView.convert(pointInWindow, from: nil)
        if collectionView.indexPathForItem(at: local) != nil { return false }
        guard let hit = window.contentView?.hitTest(pointInWindow) else { return true }
        return !(hit is NSControl || hit.superview is NSControl)
    }

    /// 在空白处拖动 = 移动窗口；带修饰键拖动 = 交给网格做框选。
    /// 自己算位置是为了把窗口限制在屏幕可见范围内（AppKit 自带拖动做不到）。
    private func installBackgroundDrag() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return event }
            // 关键：addLocalMonitorForEvents 是**应用级**监听，每个窗口控制器都会收到
            // 所有鼠标事件。必须用它判断"这个事件是不是发生在我这个窗口里"，
            // 否则在窗口 B 的把手按下时，窗口 A 也会把自己判定成"正在拖动"，
            // 一拖多个窗口就一起动、叠在一起（实测踩到过）。
            guard event.window === window else {
                self.isDraggingWindow = false
                return event
            }
            switch event.type {
            case .leftMouseDown:
                // 用户在这个窗口上按下鼠标 = 焦点回来了（本窗口是 nonactivating panel，
                // 不会让应用变成前台，所以不能靠"我是前台应用"判断）。
                self.setFocus(true)
                let mods: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
                guard event.modifierFlags.intersection(mods).isEmpty else { self.isDraggingWindow = false; return event }
                let point = event.locationInWindow

                // 顶部把手条 = 移动窗口
                if self.isInDragHandle(point) {
                    self.dragGrabOffset = point
                    self.isDraggingWindow = true
                    self.lastDragOrigin = nil
                    self.pendingBackgroundClick = false
                    return event
                }
                self.isDraggingWindow = false

                self.pendingBackgroundClick = self.isBackgroundClick(at: point)
                return event
            case .leftMouseDragged:
                self.dragMoved = true
                guard self.isDraggingWindow else { return event }
                guard let screen = window.screen ?? NSScreen.main else { return nil }
                let mouse = NSEvent.mouseLocation
                var origin = CGPoint(x: mouse.x - self.dragGrabOffset.x, y: mouse.y - self.dragGrabOffset.y)
                let visible = screen.visibleFrame
                let size = window.frame.size
                // 关键：整窗必须留在可见区域内，别跑到屏幕外
                let minX = visible.minX
                let maxX = max(visible.minX, visible.maxX - size.width)
                let minY = visible.minY
                let maxY = max(visible.minY, visible.maxY - size.height)
                origin.x = min(max(origin.x, minX), maxX)
                origin.y = min(max(origin.y, minY), maxY)

                // 拖动过程中**不吸附**，只把位置限制在屏幕内 —— 跟手才顺。
                // 吸附留到松手时做，否则一越过阈值窗口就跳一下，来回穿越就抖。
                self.lastDragOrigin = origin
                window.setFrameOrigin(origin)
                return nil
            case .leftMouseUp:
                let moved = self.dragMoved
                let wasClick = self.pendingBackgroundClick
                let wasDragging = self.isDraggingWindow
                self.pendingBackgroundClick = false
                self.isDraggingWindow = false
                self.dragMoved = false
                // 松手才吸附：边缘优先，其余对齐网格
                if wasDragging, moved, ViewSettings.windowSnap,
                   let origin = self.lastDragOrigin,
                   let screen = window.screen ?? NSScreen.main {
                    let target = Self.snapped(origin,
                                              visible: screen.visibleFrame,
                                              size: window.frame.size,
                                              tolerance: ViewSettings.snapTolerance,
                                              grid: ViewSettings.snapGrid)
                    if target != window.frame.origin {
                        // 用短动画收尾，避免生硬跳变
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.12
                            ctx.allowsImplicitAnimation = true
                            window.animator().setFrameOrigin(target)
                        }
                    }
                }
                // 单击**空白处**（没有拖动）→ 显示桌面（隐藏其他应用）。
                // 点文件格不会触发（上面已精确排除），所以不会再"点一下就跳访达"。
                // 防抖按**时间**算，不要按 clickCount。
                // 之前用 `event.clickCount == 1`：系统的双击间隔默认 0.5 秒（能调到 1 秒以上），
                // 于是"想收回来"的第二下经常落在间隔里被直接丢掉 —— 手感就是
                // "点一下没反应，得再点一下"。改成 200ms 内算一次（防闪），之后就每下都算数。
                if wasClick, !moved,
                   Date().timeIntervalSince(self.lastDesktopToggle) > 0.2 {
                    self.lastDesktopToggle = Date()
                    self.showDesktop()
                }
                return event
            default:
                return event
            }
        }
    }

    /// 吸附计算（纯函数，便于自检）：
    /// 1. 先贴屏幕四边（在容差内就吸住）
    /// 2. 其余方向对齐到网格（以可见区原点为基准，这样多个窗口的网格是齐的）
    static func snapped(_ origin: CGPoint,
                        visible: NSRect,
                        size: CGSize,
                        tolerance: CGFloat,
                        grid: CGFloat) -> CGPoint {
        let minX = visible.minX
        let maxX = max(visible.minX, visible.maxX - size.width)
        let minY = visible.minY
        let maxY = max(visible.minY, visible.maxY - size.height)
        var p = CGPoint(x: min(max(origin.x, minX), maxX),
                        y: min(max(origin.y, minY), maxY))

        // 边缘优先
        if abs(p.x - minX) < tolerance { p.x = minX }
        else if abs(p.x - maxX) < tolerance { p.x = maxX }
        if abs(p.y - minY) < tolerance { p.y = minY }
        else if abs(p.y - maxY) < tolerance { p.y = maxY }

        // 网格（边缘已吸住的轴不动，避免把贴合又推开）
        if p.x != minX && p.x != maxX {
            let gx = ((p.x - minX) / grid).rounded() * grid + minX
            if abs(p.x - gx) < tolerance { p.x = gx }
        }
        if p.y != minY && p.y != maxY {
            let gy = ((p.y - minY) / grid).rounded() * grid + minY
            if abs(p.y - gy) < tolerance { p.y = gy }
        }
        return p
    }

    /// 屏幕变化 / 尺寸变化后，把窗口拉回可见范围
    private func clampToVisibleScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// 模拟"点桌面"的效果：把其他应用都藏起来，桌面和本组件留在屏幕上。
    /// 本组件是钉在桌面层的非激活面板，所以不会被一起藏掉。

    /// 显示桌面：隐藏其他应用。只在**点击空白处**时触发（点文件不触发）。
    /// 点组件空白处 = 看桌面。
    ///
    /// 直接借用**系统自己的"显示桌面"**（就是 Fn+F11 那个），而不是自己隐藏其他应用：
    /// 系统那套窗口是"滑到一边"的，再触发一次自己滑回来，动画和手感都是原生的；
    /// 自己用 `hideOtherApplications()` 则是凭空消失、还得自己想办法还原。
    ///
    /// 顺带记一下为什么不用私有 API：老办法是给 Dock 发
    /// `CoreDockSendNotification("com.apple.showdesktop.awake")`，
    /// 但 macOS 15 上 CoreDock 这个私有框架已经不在系统里了（`dlopen` 直接失败）。
    /// 发快捷键这条路人畜无害、也不用任何授权。
    ///
    /// 依赖：系统设置 → 键盘 → 键盘快捷键 → 调度中心 → **显示桌面**（默认 Fn+F11）。
    ///
    /// **合成按键需要「辅助功能」权限**。本应用默认没有这个权限，系统会把按键直接丢掉
    /// —— 实测：从终端起的实例（继承终端的权限）点了有效，正常双击启动的实例点了没反应。
    /// 所以这里先问一下自己有没有权限：没有就退回"隐藏/恢复其他应用"
    /// （`hideOtherApplications()` 是 NSWorkspace 级别的，不需要任何授权）。
    func showDesktop() {
        // 顺序有讲究：先把快捷键发出去（延迟敏感），再管窗口层级。
        // 反过来先在窗口服务器上走一趟，观感上就慢半拍。
        if AXIsProcessTrusted(), postShowDesktopHotkey() {
            window?.orderFrontRegardless()
            return
        }
        toggleHideOtherApplications()
        window?.orderFrontRegardless()
    }

    /// 兜底方案用：上一次收起时被请走的应用，用来原样放回来
    private var hiddenForPeek: [NSRunningApplication] = []
    private var peekedApp: NSRunningApplication?

    private func toggleHideOtherApplications() {
        if !hiddenForPeek.isEmpty {
            // 只靠 activate：`unhide()` 走 Apple Event，后台应用调用会被直接拒掉；
            // 而"激活一个隐藏的应用"是 LaunchServices 级别的，不需要任何授权，
            // 系统会顺手把它取消隐藏。最后再回到点之前那个前台应用。
            let apps = hiddenForPeek
            hiddenForPeek = []
            for app in apps { app.activate(options: []) }
            peekedApp?.activate(options: [])
            peekedApp = nil
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        hiddenForPeek = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != me
                && $0.bundleIdentifier != "com.apple.finder"   // 访达留着，桌面图标靠它
                && !$0.isHidden
        }
        // 关键：`.accessory`（后台应用）状态下 hideOtherApplications() 是**无效的**
        // —— 实测调用完 Edge 照样露在外面。先把自己激活成"当前应用"再隐藏其他。
        AppActivation.toFront()
        NSWorkspace.shared.hideOtherApplications()
        peekedApp = (front?.processIdentifier != me) ? front : nil
    }

    /// 触发系统的"显示桌面"：F11 + Fn 修饰键 = 默认的那个快捷键
    @discardableResult
    /// 触发系统的"显示桌面"：F11 + Fn 修饰键 = 默认的那个快捷键。
    /// 合成按键需要「辅助功能」权限，没有权限时会被系统丢掉（见 showDesktop）。
    func postShowDesktopHotkey() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 103, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 103, keyDown: false) else {
            return false
        }
        down.flags = .maskSecondaryFn
        up.flags = .maskSecondaryFn
        down.post(tap: .cghidEventTap)
        // keyUp 走异步。**绝对不要在这里 usleep** ——
        // 之前那 60ms 是主线程硬阻塞：点完空白处立刻动鼠标、或者再点一下，
        // 整个应用还僵在那儿，手感就是"卡手"。系统识别快捷键只看 keyDown，
        // 所以 keyUp 晚 20ms 补上完全没问题。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private func setOverlayVisible(_ visible: Bool, animated: Bool) {
        guard overlayVisible != visible else { return }
        overlayVisible = visible
        if visible { overlay.isHidden = false }
        grip?.alphaValue = visible ? 1 : 0.45
        let changes = { self.overlay.alphaValue = visible ? 1 : 0 }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                changes()
            } completionHandler: { [weak self] in
                guard let self, !self.overlayVisible else { return }
                self.overlay.isHidden = true
            }
        } else {
            changes()
            overlay.isHidden = !visible
        }
    }

    // MARK: - 层级

    func applyLevelMode(_ mode: WindowLevelMode) {
        levelMode = mode
        guard let window else { return }
        mode.apply(to: window)
        window.orderFrontRegardless()
    }

    @objc private func cycleLevelMode() {
        let all = WindowLevelMode.allCases
        let next = all[(all.firstIndex(of: levelMode).map { $0 + 1 } ?? 0) % all.count]
        applyLevelMode(next)
        onLevelModeChanged?(next)
    }

    // MARK: - 菜单：功能都收在这里

    @objc private func closeWindow() {
        // 不能用 performClose(_:)：本窗口是 .borderless，没有关闭按钮，
        // performClose 找不到按钮就什么都不做 —— 表现就是"小窗关不掉"。
        animateOut { [weak self] in self?.window?.close() }
    }

    // MARK: - 出现 / 消失动画

    /// 淡入 + 从稍小一圈展开。
    /// 桌面组件这种东西"凭空啪一下出现"很出戏，加个 0.16 秒的收放就自然多了。
    func animateIn() {
        guard let window, window.isVisible, !isAnimatingFrame else { return }
        let finalFrame = window.frame
        let startFrame = finalFrame.insetBy(dx: 14, dy: 14)
        window.alphaValue = 0
        window.setFrame(startFrame, display: false)
        isAnimatingFrame = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimatingFrame = false
            self.refreshLayoutForCurrentSize()
        })
    }

    /// 淡出 + 收一圈，收完再真正关掉
    func animateOut(completion: @escaping () -> Void) {
        guard let window, window.isVisible, !isAnimatingFrame else {
            completion()
            return
        }
        let endFrame = window.frame.insetBy(dx: 14, dy: 14)
        isAnimatingFrame = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimatingFrame = false
            completion()
        })
    }

    /// 窗口作用域的 ⌘ 键。
    /// `.accessory` 应用不会激活，**主菜单的快捷键根本不会被派发**（README 里那几个
    /// ⌘D/⌘O/⌘W 之前其实全是死的）；所以由 AppDelegate 装的应用级监听路由过来。
    /// 返回 true 表示已处理。
    func handleCommandKey(_ key: String) -> Bool {
        switch key {
        case "w": closeWindow(); return true
        case "[": goToParent(); return true
        case "r": revealInFinder(); return true
        case "o": chooseFolder(); return true
        case "n": onOpenAnotherWindow?(); return true
        default: return false
        }
    }

    @objc private func showMoreMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: folderURL.lastPathComponent, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let pathItem = NSMenuItem(title: Self.abbreviatedPath(folderURL), action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        menu.addItem(.separator())
        add(menu, "换一个文件夹…", #selector(chooseFolder), "o")
        // 已经在卷宗根（"主目录"）了就置灰，省得点了没反应
        add(menu, "回到上一级", #selector(goToParent), "[").isEnabled = canGoToParent
        add(menu, "在访达中显示", #selector(revealInFinder), "r")
        // 手动重试：刚在系统设置里授过权、或者 FSEvents 漏了事件时用
        add(menu, "重新载入", #selector(reloadNow), "")

        menu.addItem(.separator())

        // 显示方式
        let modeParent = NSMenuItem(title: "显示方式", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "显示方式")
        for m in ViewMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (ViewSettings.mode == m) ? .on : .off
            modeMenu.addItem(item)
            if m == .list { viewModeItem = item }
        }
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        // 整理方式：直接照搬访达图标视图那一套
        //   无 / 贴靠网格 / 按名称 / 按修改日期 / 按大小 / 按种类
        let arrangeParent = NSMenuItem(title: "整理方式", action: nil, keyEquivalent: "")
        let arrangeMenu = NSMenu(title: "整理方式")
        arrangeItems = []
        for m in ArrangeMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickArrangeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (ViewSettings.arrange == m) ? .on : .off
            arrangeMenu.addItem(item)
            arrangeItems.append(item)
        }
        arrangeMenu.addItem(.separator())
        // 访达里「整理」只在 无/贴靠网格 下可用（排好序的时候没什么可整理的）
        add(arrangeMenu, "整理", #selector(tidyIcons), "").isEnabled = ViewSettings.arrange.isFree
        add(arrangeMenu, "重排（恢复默认位置）", #selector(resetPlacement), "")
        arrangeParent.submenu = arrangeMenu
        menu.addItem(arrangeParent)

        // 排序方式：访达里它和"整理方式"是**两件事** ——
        // 整理方式选了"按xx"时，排序由整理方式决定，这一项是灰的。
        let orderParent = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
        let orderMenu = NSMenu(title: "排序方式")
        sortItems = []
        for mode in SortMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickSortMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (ViewSettings.sort == mode) ? .on : .off
            orderMenu.addItem(item)
            sortItems.append(item)
        }
        orderParent.submenu = orderMenu
        orderParent.isEnabled = ViewSettings.arrange.isFree
        orderParent.title = ViewSettings.arrange.isFree ? "排序方式" : "排序方式（由整理方式决定）"
        menu.addItem(orderParent)

        menu.addItem(.separator())
        let levelParent = NSMenuItem(title: "窗口层级", action: nil, keyEquivalent: "")
        let levelMenu = NSMenu(title: "窗口层级")
        for mode in WindowLevelMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickLevelMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == levelMode) ? .on : .off
            levelMenu.addItem(item)
        }
        levelParent.submenu = levelMenu
        menu.addItem(levelParent)

        let snapItem = NSMenuItem(title: "拖动时吸附",
                                  action: #selector(toggleWindowSnap(_:)), keyEquivalent: "")
        snapItem.target = self
        snapItem.state = ViewSettings.windowSnap ? .on : .off
        menu.addItem(snapItem)

        let openNew = NSMenuItem(title: "再开一个窗口…", action: #selector(AppDelegate.openNewWindow), keyEquivalent: "n")
        openNew.target = NSApp.delegate
        menu.addItem(openNew)

        menu.addItem(.separator())
        add(menu, "关闭这个组件", #selector(closeWindow), "w")

        if let event = NSApp.currentEvent, event.type == .rightMouseDown {
            NSMenu.popUpContextMenu(menu, with: event, for: canvas)
        } else {
            let point = NSPoint(x: canvas.bounds.maxX - 34, y: canvas.bounds.minY + 34)
            menu.popUp(positioning: nil, at: point, in: canvas)
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func pickLevelMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowLevelMode(rawValue: raw) else { return }
        applyLevelMode(mode)
        onLevelModeChanged?(mode)
    }

    /// 还能不能往上退。
    /// 「主目录」= 当前目录所在的**卷宗根**：退到那里就停，
    /// 不会被带到另一块盘（比如从外置盘退到 Macintosh HD 的 /）。
    /// 注意这只限制"往上退"这一个动作 —— ⌘O 换文件夹想去哪都行；
    /// 换到别的盘之后，上限就跟着变成那块盘的根。
    var canGoToParent: Bool { Self.canGoUp(from: folderURL) }

    /// 纯函数版（便于确定性自检）
    static func canGoUp(from folder: URL) -> Bool {
        let current = folder.standardizedFileURL.path
        let root = volumeRoot(of: folder)
        guard current != root else { return false }
        let parent = folder.deletingLastPathComponent().standardizedFileURL.path
        return parent != current && parent.hasPrefix(root)
    }

    @objc private func goToParent() {
        guard canGoToParent else {
            NSSound.beep()      // 到顶了：响一声，别让人以为点了没反应
            return
        }
        bindFolder(folderURL.deletingLastPathComponent())
        onClose?()
    }

    // MARK: - 绑定目录 + 监听

    private var changedSubpaths: Set<String> = []
    private var changedFolders: Set<String> = []
    /// 当前目录**读不了**（TCC 没授权 / EACCES）：窗口里要给"去哪儿开权限"的提示，
    /// 状态栏菜单也会因此多出一项「打开权限设置」
    private(set) var accessDenied = false
    private var generation = 0
    private var hasLoadedOnce = false

    func bindFolder(_ url: URL) {
        watcher?.stop()
        folderURL = url
        changedSubpaths.removeAll()
        changedFolders.removeAll()
        hasLoadedOnce = false

        let watcher = DirectoryWatcher(path: url.path) { [weak self] changedPaths in
            self?.noteChanges(changedPaths)
            self?.reload()
        }
        watcher.start()
        self.watcher = watcher

        window?.representedURL = url
        window?.title = Self.abbreviatedPath(url)
        nameLabel?.stringValue = Self.abbreviatedPath(url)
        nameLabel?.toolTip = url.path      // 悬停给完整绝对路径
        updateStatus()
        reload()
    }

    /// 把路径缩到"够看就行"。**盘就是顶层 `/`**（和"回到上一级"的上限是同一条规矩）：
    ///   /Volumes/ExampleDisk              → /
    ///   /Volumes/ExampleDisk/Applications → /Applications
    ///   /Volumes/ExampleDisk/a/b/c/d      → /a/…/c/d
    ///   ~/Desktop              → ~/Desktop
    /// 完整绝对路径仍然在悬停提示和 ⋯ 菜单里。
    static func abbreviatedPath(_ url: URL) -> String {
        let target = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        if target.path == home.path || target.path.hasPrefix(home.path + "/") {
            let rest = String(target.path.dropFirst(home.path.count))
            return rest.isEmpty ? "~" : "~" + rest
        }

        // 卷宗根当成 "/"：外置盘上的 "/Volumes/ExampleDisk" 这一段不用显示
        let root = volumeRoot(of: target)
        if root != "/", target.path.hasPrefix(root) {
            let rest = String(target.path.dropFirst(root.count))
            return rest.isEmpty ? "/" : elideMiddle(rest)
        }
        return elideMiddle(target.path)
    }

    /// 找出路径所在的卷宗根。
    /// 先问系统（准确），拿不到就按 `/Volumes/<名字>` 这条规则推 ——
    /// 路径不存在时 `volumeURLKey` 会返回 nil，不能只靠它。
    static func volumeRoot(of url: URL) -> String {
        if let v = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume)?
            .standardizedFileURL.path, v != "/" {
            return v
        }
        let parts = url.standardizedFileURL.path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/" + parts[1] }
        return "/"
    }

    /// 超过三段就从中间省略：/a/b/c/d → /a/…/c/d（保留最有辨识度的头尾）
    private static func elideMiddle(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 3 else { return path.hasPrefix("/") ? path : "/" + path }
        return "/" + parts[0] + "/…/" + parts.suffix(2).joined(separator: "/")
    }

    private func noteChanges(_ paths: [String]) {
        let root = folderURL.path
        for path in paths {
            guard path.hasPrefix(root) else { continue }
            let suffix = path.dropFirst(root.count)
            guard let first = suffix.split(separator: "/").first else { continue }
            changedSubpaths.insert(String(first))
        }
    }

    /// 唯一的刷新入口：所有文件系统 I/O 都在后台队列
    func reload() {
        let directory = folderURL
        generation += 1
        let myGeneration = generation

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            // 读不到的时候**别把错误吞掉**：受 TCC 保护的目录（桌面/文稿/下载/外置盘/网络卷）
            // 没授权时这里会抛 EACCES，之前 `try? … ?? []` 会把它变成"一个空文件夹"，
            // 看着就像"这个目录是锁死的"，也完全不知道该怎么办。
            var denied = false
            var flat: [URL] = []
            do {
                flat = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles])
            } catch {
                denied = Self.isPermissionError(error)
                if !denied { print("[FolderSync] 列目录失败 \(directory.path): \(error)") }
            }
            let entries: [(url: URL, relative: String)] = flat.map { ($0, "") }
            let truncated = false

            // **先把要排序用的属性取一次**。
            //
            // 原来是在比较闭包里各调一次 `resourceValues` —— 那是一次系统调用，
            // 而比较会被调用 O(n log n) 次：1000 个文件就是两万次上下（网络盘/云盘
            // 上每次都可能是磁盘或网络往返）。这里每个文件只取一次。
            let sortMode = ViewSettings.sort
            struct Entry {
                let url: URL
                let relative: String
                let isDirectory: Bool
                let size: Int
                let modified: Date?
            }
            let prepared: [Entry] = entries.map { entry in
                let values = try? entry.url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return Entry(url: entry.url,
                             relative: entry.relative,
                             isDirectory: values?.isDirectory ?? false,
                             size: values?.fileSize ?? 0,
                             modified: values?.contentModificationDate)
            }
            let sorted = prepared.sorted { lhs, rhs in
                // 文件夹始终排在前面（和访达一致）
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                switch sortMode {
                case .name:
                    return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                case .dateModified:
                    return (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast)
                case .size:
                    return lhs.size > rhs.size
                case .kind:
                    let ae = lhs.url.pathExtension.lowercased(), be = rhs.url.pathExtension.lowercased()
                    if ae != be { return ae < be }
                    return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }
            }
            var loaded = sorted.map { FileItem(url: $0.url, relativeFolder: $0.relative) }
            // 隐藏后缀后如果重名，就把重名的恢复成全名（访达的规则）
            FileItem.resolveDisplayNameConflicts(&loaded)

            _ = truncated

            let subpaths = self?.changedSubpaths ?? []
            let marked = Set(loaded.filter {
                $0.isDirectory && subpaths.contains($0.url.lastPathComponent)
            }.map { $0.url.path })

            DispatchQueue.main.async {
                guard let self, self.generation == myGeneration else { return }
                self.items = loaded
                self.changedFolders = marked
                self.accessDenied = denied
                self.hasLoadedOnce = true
                if ViewSettings.freePlacement && ViewSettings.mode == .icon {
                    self.buildIconLayout()
                }
                self.collectionView.reloadData()
                // reloadData 后尺寸才稳定，强制重排一次避免用旧的 viewport
                if ViewSettings.freePlacement && ViewSettings.mode == .icon {
                    self.collectionView.collectionViewLayout?.invalidateLayout()
                }
                self.updateStatus()
                ReloadTrace.record(folder: directory.path, items: loaded.map { $0.name })
            }
        }
    }

    private func updateStatus() {
        if !hasLoadedOnce {
            setStatusDot(.systemOrange)
            return
        }
        // 只留一个小圆点：绿=同步中，蓝=刚有变化
        setStatusDot(accessDenied ? .systemRed : (changedFolders.isEmpty ? .systemGreen : .systemBlue))
        let isEmpty = items.isEmpty
        emptyIconView.isHidden = !isEmpty
        emptyLabel.isHidden = !isEmpty
        guard isEmpty else { return }

        // 空是因为**没权限**，不是因为这个目录本来就空 —— 这两件事必须分清楚，
        // 否则用户看到的就是"这个文件夹被锁死了，什么也没有"。
        if accessDenied {
            emptyIconView.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "没有权限")
            emptyLabel.stringValue = "没有权限读取这个文件夹\n"
                + "点右上角 ⋯ →「重新载入」重试，或到「系统设置 → 隐私与安全性 → 文件与文件夹」里允许 FolderSync\n"
                + "（状态栏图标菜单里有一键打开该设置）"
        } else {
            emptyIconView.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
            emptyLabel.stringValue = "拖文件进来，或往这个文件夹里放东西"
        }
    }

    /// 是不是"没权限读"（TCC 拒绝 / POSIX EACCES）。
    /// 用来在窗口里给出"去哪儿开权限"的提示，而不是显示成一个空文件夹。
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoPermissionError || ns.code == 513 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EACCES) { return true }
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(EACCES)
    }

    private func setStatusDot(_ color: NSColor) {
        statusDot.layer?.backgroundColor = color.withAlphaComponent(0.8).cgColor
    }

    // MARK: - 双向写入

    private func handleDrop(urls: [URL], move: Bool) {
        _ = FileOps.ingest(urls: urls, into: folderURL, move: move)
        reload()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = "选择"
        panel.message = "选择这个窗口要实时展示的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            bindFolder(url)
            onClose?()
        }
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    @objc private func reloadNow() {
        reload()
    }

    @objc private func openSelection() {
        for url in selectedURLs() { openItem(at: url) }
    }

    /// 统一入口：文件夹交给**访达**，其它交给系统默认应用。
    ///
    /// 不能对文件夹直接用 `NSWorkspace.shared.open(url)`：那会走系统里
    /// `public.folder` 的"默认打开方式"，而那个默认值未必是访达
    /// （实测这台机器上是 `com.apple.archiveutility`；如果被设成 FolderSync，
    /// 表现就是"右键→打开一个文件夹，结果又开出一个 FolderSync"）。
    func openItem(at url: URL) {
        // 逻辑只有一份：文件夹→访达，其它→默认应用（见 FileOps.open）
        FileOps.open(url)
    }

    @objc func trashSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        FileOps.moveToTrash(urls)
        reload()
    }

    private func selectedURLs() -> [URL] {
        let source = items
        return collectionView.selectionIndexPaths.compactMap { indexPath in
            source.indices.contains(indexPath.item) ? source[indexPath.item].url : nil
        }
    }

    private func activate(_ indexPath: IndexPath) {
        let source = items
        guard source.indices.contains(indexPath.item) else { return }
        let item = source[indexPath.item]

        // 双击文件夹 → 在访达里打开（不再"进入下一层"替换当前目录）。
        // 想下钻：右键 → 在此窗口中打开；想开小窗：右键 → 在旁边开小窗口。
        // 包（.app 之类）虽然也是目录，但双击的语义是"打开这个 app"，
        // 不能走"在访达里打开文件夹"那条路 —— 否则双击应用只会跳访达。
        if item.isDirectory && !item.isPackage {
            // 双击 = 在访达打开。
            // 「在旁边开小窗口」只放在**右键文件夹**的菜单里，不做快捷方式，避免和双击混淆。
            FileOps.openInFinder(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// 右键菜单。结构照访达：
    ///   打开 / 打开方式 ▸ / ─ / （在新组件窗口中打开）/ 在访达中显示 / ─ / 拷贝 / 重新命名… / ─ / 移到废纸篓
    /// 右键的那一项若本来就在多选里，就作用于整个选择（访达也是这样）。
    private func menu(for indexPath: IndexPath, in view: NSView) -> NSMenu? {
        guard items.indices.contains(indexPath.item) else { return nil }
        let item = items[indexPath.item]

        let targets: [URL]
        if collectionView.selectionIndexPaths.contains(indexPath), selectionIndexPathsCount > 1 {
            targets = selectedURLs()
        } else {
            targets = [item.url]
        }
        guard !targets.isEmpty else { return nil }

        let menu = NSMenu()
        let single = targets.count == 1 ? targets[0] : nil
        let displayName = single?.lastPathComponent ?? "\(targets.count) 项"

        // ① 打开
        addTo(menu, "打开", #selector(openContextItem(_:)), targets)

        // ② 打开方式 ▸（访达只对"文件"给这一项）
        if !item.isDirectory || item.isPackage {
            let parent = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "打开方式")
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
            if apps.isEmpty {
                let none = NSMenuItem(title: "没有可用的应用", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            for app in apps.prefix(10) {
                let appItem = NSMenuItem(title: FileManager.default.displayName(atPath: app.path),
                                         action: #selector(openContextItemWith(_:)), keyEquivalent: "")
                appItem.target = self
                appItem.representedObject = [targets, app] as [Any]
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                appItem.image = icon
                submenu.addItem(appItem)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        } else {
            // 文件夹：访达这里是"在新标签页中打开 / 在新窗口中打开"，
            // 我们没有标签页，对应的是"在新组件窗口中打开"
            addTo(menu, "在新组件窗口中打开", #selector(satelliteContextItem(_:)), targets)
        }

        menu.addItem(.separator())

        // ③ 移到废纸篓（访达这一项不带文件名）
        addTo(menu, "移到废纸篓", #selector(trashContextItem(_:)), targets)

        menu.addItem(.separator())

        // ④ 拷贝 / 制作替身 / 复制
        addTo(menu, "拷贝", #selector(copyContextItem(_:)), targets)
        addTo(menu, "制作替身", #selector(aliasContextItem(_:)), targets)
        addTo(menu, "复制", #selector(duplicateContextItem(_:)), targets)

        menu.addItem(.separator())

        // ⑤ 快速查看
        addTo(menu, "快速查看", #selector(quickLookContextItem(_:)), targets)

        menu.addItem(.separator())

        // ⑥ 显示简介
        addTo(menu, "显示简介", #selector(infoContextItem(_:)), targets)

        menu.addItem(.separator())

        // ⑦ 给…添加标签 ▸（访达那七种颜色；已有的会打勾）
        let tagParent = NSMenuItem(title: "给…添加标签", action: nil, keyEquivalent: "")
        let tagMenu = NSMenu(title: "给…添加标签")
        let existing = single.map { FileOps.tags(of: $0).map { $0.components(separatedBy: "\n").first ?? $0 } } ?? []
        for tag in FileOps.FinderTag.all {
            let tagItem = NSMenuItem(title: tag.name, action: #selector(addTagContextItem(_:)), keyEquivalent: "")
            tagItem.target = self
            tagItem.representedObject = [targets, tag.name, tag.colorIndex] as [Any]
            tagItem.state = existing.contains(tag.name) ? .on : .off
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                tag.color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
            tagItem.image = dot
            tagMenu.addItem(tagItem)
        }
        tagMenu.addItem(.separator())
        let clearTags = NSMenuItem(title: "清除所有标签", action: #selector(clearTagsContextItem(_:)), keyEquivalent: "")
        clearTags.target = self
        clearTags.representedObject = targets
        tagMenu.addItem(clearTags)
        tagParent.submenu = tagMenu
        menu.addItem(tagParent)

        menu.addItem(.separator())

        // ⑧ 压缩（访达的标题带文件名）
        addTo(menu, "压缩「\(displayName)」", #selector(compressContextItem(_:)), targets)

        // ⑨ 共享（直接用系统给的那一项：标题、子菜单、可用服务都由它决定，和访达一致）
        menu.addItem(NSSharingServicePicker(items: targets).standardShareMenuItem)

        // ⑩ 组件自己才有的一项（访达没有）：在访达里定位
        menu.addItem(.separator())
        addTo(menu, item.isDirectory && !item.isPackage ? "在访达中打开" : "在访达中显示",
              #selector(revealContextItem(_:)), targets)

        return menu
    }

    /// 右键菜单里的一项：目标 URL 挂在 representedObject 上
    @discardableResult
    private func addTo(_ menu: NSMenu, _ title: String, _ action: Selector, _ targets: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = targets
        menu.addItem(item)
        return item
    }

    private var selectionIndexPathsCount: Int { collectionView.selectionIndexPaths.count }

    // MARK: - 右键菜单的动作

    @objc private func openContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        for url in urls { openItem(at: url) }
    }

    /// 「打开方式 ▸」选了某个应用
    @objc private func openContextItemWith(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [Any],
              let urls = payload.first as? [URL],
              let app = payload.last as? URL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, error in
            if let error { NSLog("[FolderSync] 用指定应用打开失败: \(error)") }
        }
    }

    @objc private func satelliteContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], let url = urls.first else { return }
        (NSApp.delegate as? AppDelegate)?.openSatelliteWindow(for: url, beside: window)
    }

    @objc private func revealContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        for url in urls { FileOps.openInFinder(url) }
    }

    /// 拷贝 = 把文件本身放进剪贴板（跟访达一样，可以在别处 ⌘V）
    @objc private func copyContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// 重新命名（弹一个只有输入框的对话框；访达是原地编辑，这里用对话框，行为等价）
    @objc private func renameContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], let url = urls.first else { return }
        let alert = NSAlert()
        alert.messageText = "重新命名"
        alert.informativeText = "为「\(url.lastPathComponent)」输入新名称"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.lastPathComponent
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            NSSound.beep()
            NSLog("[FolderSync] 重新命名失败: \(error)")
        }
        reload()
    }

    /// 快速查看（空格键 / 右键菜单那一项，都走这里）
    ///
    /// 之前**空格根本没接**（`keyDown` 里只有 Delete / Return），所以只有右键菜单能用，
    /// 而菜单那条又因为本 app 是 `.accessory`（从不激活）—— `QLPreviewPanel` 要能成为 key
    /// 才可用，先 `NSApp.activate` 再 `makeKeyAndOrderFront`，否则面板要么不出现、要么点不动。
    private func toggleQuickLookForSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        // 选中的是**单个文件夹** → 自研预览浮层（系统 Quick Look 对文件夹只会画大图标，
        // 不列内容）；其余情况（文件、多选）→ 系统 Quick Look。
        if urls.count == 1, isDirectory(urls[0]) {
            toggleFolderPreview(for: urls[0])
            return
        }
        folderPreview?.close()
        folderPreview = nil
        collectionView.previewURLs = urls
        collectionView.toggleQuickLook()
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
    }

    /// 再按一次空格收掉；换一个文件夹则重建
    private func toggleFolderPreview(for url: URL) {
        if let preview = folderPreview, preview.isVisible, preview.folderURL == url {
            preview.close()
            folderPreview = nil
            return
        }
        folderPreview?.close()
        guard let window else { return }
        let preview = FolderPreviewController(folderURL: url, parent: window, levelMode: levelMode)
        preview.onPin = { [weak self] target in
            self?.folderPreview = nil
            self?.onOpenFolderPermanently?(target)
        }
        folderPreview = preview
        preview.show()
    }

    @objc private func quickLookContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        // 和空格键**同一套分流**：单个文件夹 → 自研预览浮层（系统 QL 对文件夹只有大图标）；
        // 其余 → 系统 Quick Look。菜单是真实手势，激活不会被系统打回，所以这条是稳的。
        if urls.count == 1, isDirectory(urls[0]) {
            toggleFolderPreview(for: urls[0])
            return
        }
        folderPreview?.close()
        folderPreview = nil
        collectionView.previewURLs = urls
        collectionView.showQuickLook()
    }

    /// 给…添加标签：优先找系统里能打开它的应用
    @objc private func addTagContextItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [Any],
              let urls = payload.first as? [URL],
              let name = payload.count > 1 ? payload[1] as? String : nil,
              let colorIndex = payload.count > 2 ? payload[2] as? Int : nil,
              let tag = FileOps.FinderTag.all.first(where: { $0.name == name && $0.colorIndex == colorIndex })
        else { return }
        _ = FileOps.addTag(tag, to: urls)
        reload()
    }

    @objc private func clearTagsContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        _ = FileOps.clearTags(of: urls)
        reload()
    }


    /// 制作替身
    @objc private func aliasContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        _ = FileOps.makeAlias(urls)
        reload()
    }

    /// 复制（访达的 ⌘D）
    @objc private func duplicateContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        _ = FileOps.duplicate(urls)
        reload()
    }

    /// 压缩成 zip
    @objc private func compressContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        _ = FileOps.compress(urls)
        reload()
    }

    /// 显示简介（自己拼一段信息，不依赖访达 —— 访达的"显示简介"没有公开 API）
    @objc private func infoContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "简介" : "简介（\(urls.count) 项）"
        alert.informativeText = urls.map { FileOps.infoText(for: $0) }.joined(separator: "\n\n")
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func trashContextItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        FileOps.moveToTrash(urls)
        reload()
    }

    // MARK: - 自检入口（仅用于 --selftest，走真实视图与代码路径）

    var marqueeTestView: FolderCollectionView { collectionView }
    var testItemCount: Int { items.count }
    func testClampToScreen() { clampToVisibleScreen() }
    /// 自检用：返回浮层按钮的实际尺寸与圆角
    func testButtonGeometry() -> (CGSize, CGFloat)? {
        guard let button = overlay.subviews.compactMap({ $0 as? OverlayButton }).first else { return nil }
        return (button.frame.size, button.layer?.cornerRadius ?? -1)
    }

    // MARK: - 视图：图标 / 列表、图标大小、排序

    @objc private func iconSizeChanged(_ sender: NSSlider) {
        ViewSettings.iconSize = CGFloat(sender.doubleValue)
        applyLayout()
    }

    /// 按当前视图偏好重建布局
    func applyLayout() {
        let mode = ViewSettings.mode
        sizeSlider?.isHidden = (mode != .icon)
        updateListHeader(visible: mode == .list)
        listBackdrop?.isHidden = (mode != .list)
        // 这里**故意不设** contentInsets：底部那条给"图标大小"滑块让位的位置由
        // IconLayout 自己留（contentInsets 会给内容加出一条可滚空间，
        // 于是图标全放得下的时候也能滚、滚动条也冒出来）。
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.isHidden = false
        if let canvas {
            scrollView.frame = NSRect(x: 0, y: dragHandleHeight,
                                      width: canvas.bounds.width,
                                      height: max(60, canvas.bounds.height - dragHandleHeight))
        }

        if mode == .list {
            rebuildListLayout()
            return
        }
        // 滚动条整条不画（见 scrollView 初始化处的注释）；滚动能力不受影响，
        // 所以这里不再按"图标/列表"切滚动条方向。
        buildIconLayout()
        collectionView.reloadData()
    }

    /// 建（重建）列表布局 —— **只在切到列表视图时调一次**。
    /// 拉窗口时每帧重建布局 + reloadData 会让整个列表闪一下（踩过）。
    private func rebuildListLayout() {
        canvas?.layoutSubtreeIfNeeded()
        let width = listRowWidth()
        let list = NSCollectionViewFlowLayout()
        list.itemSize = NSSize(width: width, height: 32)   // 行高稍大，上下有呼吸感
        list.minimumInteritemSpacing = 0
        list.minimumLineSpacing = 0
        list.sectionInset = NSEdgeInsets(top: 5, left: 6, bottom: 10, right: 6)
        collectionView.collectionViewLayout = list
        collectionView.reloadData()
    }

    /// 拉窗口时只改行宽：不换布局对象、不 reloadData，所以不会闪
    private func resizeListLayoutToFit() {
        guard let list = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else {
            rebuildListLayout()
            return
        }
        canvas?.layoutSubtreeIfNeeded()
        let width = listRowWidth()
        guard abs(list.itemSize.width - width) > 0.5 else { return }
        list.itemSize = NSSize(width: width, height: 32)
        list.invalidateLayout()
    }

    private func listRowWidth() -> CGFloat {
        let viewport = scrollView.contentSize.width
        return max(viewport > 1 ? viewport : (canvas?.bounds.width ?? 640) - 4, 200)
    }

    @objc private func pickViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = ViewMode(rawValue: raw) else { return }
        ViewSettings.mode = m
        viewModeItem?.state = (m == .icon) ? .off : .on
        applyLayout()
    }

    @objc private func pickArrangeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ArrangeMode(rawValue: raw) else { return }
        ViewSettings.arrange = mode
        // "按xx"这几种，排序由整理方式决定（访达里排序方式那一项这时是灰的）
        if let sort = mode.sortMode { ViewSettings.sort = sort }
        for item in arrangeItems { item.state = (item.representedObject as? String == raw) ? .on : .off }
        for item in sortItems { item.state = (item.representedObject as? String == ViewSettings.sort.rawValue) ? .on : .off }
        if mode == .snapToGrid { tidyIcons() }   // 切过去的同时把已有位置对齐
        applyLayout()
    }

    @objc private func pickSortMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SortMode(rawValue: raw) else { return }
        ViewSettings.sort = mode
        for item in sortItems { item.state = (item.representedObject as? String == raw) ? .on : .off }
        reload()
    }

    /// 「整理」：把已经摆好的图标对齐到网格（访达的 Clean Up）
    @objc private func tidyIcons() {
        let positions = PlacementStore.positions(in: folderURL)
        guard !positions.isEmpty else { return }
        let grid = ViewSettings.snapGrid
        let snapped = positions.mapValues {
            NSPoint(x: ($0.x / grid).rounded() * grid, y: ($0.y / grid).rounded() * grid)
        }
        PlacementStore.setPositions(snapped, in: folderURL)
        if ViewSettings.arrange.isFree { applyLayout() }
    }

    @objc private func toggleWindowSnap(_ sender: NSMenuItem) {
        ViewSettings.windowSnap.toggle()
        sender.state = ViewSettings.windowSnap ? .on : .off
    }

    // MARK: - 穿透显示的独立小框

    // MARK: - 列表表头

    /// 列表视图顶部显示可点击排序的表头（访达样式）
    private func updateListHeader(visible: Bool) {
        if visible {
            if listHeader == nil {
                let header = ListHeaderView()
                header.translatesAutoresizingMaskIntoConstraints = false
                header.onPickSort = { [weak self] mode in
                    ViewSettings.sort = mode
                    self?.syncArrangeMenu()
                    self?.reload()
                }
                canvas.addSubview(header)
                NSLayoutConstraint.activate([
                    header.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                    header.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
                    header.topAnchor.constraint(equalTo: listBackdrop!.topAnchor),
                    header.heightAnchor.constraint(equalToConstant: 26),
                ])
                listHeader = header
                // 网格给表头让出位置
                scrollViewTopConstraint?.constant = dragHandleHeight + 26
                // 和底板左右对齐：不然行内容会溢出白桌面的圆角
                scrollLeadingConstraint?.constant = 8
                scrollTrailingConstraint?.constant = -8
                scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            }
            listHeader?.update(sort: ViewSettings.sort)
            listHeader?.isHidden = false
        } else {
            listHeader?.isHidden = true
            scrollViewTopConstraint?.constant = dragHandleHeight
            scrollLeadingConstraint?.constant = 0
            scrollTrailingConstraint?.constant = 0
        }
    }

    /// 列表表头点了某一列 = 改了排序，整理方式跟着切到对应的「按xx」，
    /// 这样 ⋯ 菜单里的勾选和实际排序永远是对得上的。
    private func syncArrangeMenu() {
        if let match = ArrangeMode.allCases.first(where: { $0.sortMode == ViewSettings.sort }) {
            ViewSettings.arrange = match
        }
        for item in arrangeItems {
            item.state = ((item.representedObject as? String) == ViewSettings.arrange.rawValue) ? .on : .off
        }
    }

    // MARK: - 自由放置

    /// 按已保存坐标构建自由放置布局
    /// 建图标布局。
    /// 自由摆放/贴靠网格 → 带上手动位置；排好序的整理方式 → 不带（位置由布局按序号生成）。
    private func buildIconLayout() {
        let layout = IconLayout()
        layout.iconSide = ViewSettings.iconSize
        layout.itemSize = GridMetrics.itemSize(iconSide: ViewSettings.iconSize)
        if ViewSettings.arrange.isFree {
            let saved = PlacementStore.positions(in: folderURL)
            var map: [IndexPath: NSPoint] = [:]
            for (index, item) in items.enumerated() {
                if let point = saved[item.name] { map[IndexPath(item: index, section: 0)] = point }
            }
            layout.positions = map
        }
        collectionView.collectionViewLayout = layout
        collectionView.needsDisplay = true
    }

    /// 把某一格拖到新位置并记住
    /// 开始"窗口内拖拽"之前，把当前所有格子的位置**钉下来**。
    ///
    /// 不钉的话：被拖走的那格会从自动排布里空出来，后面的图标就往前挤一格 ——
    /// 访达不会这样（自由摆放就是"位置不动，留下一块空"）。
    func freezeFreePlacementPositions() {
        guard ViewSettings.mode == .icon, !items.isEmpty else { return }
        // 关键：**不要**先判断"当前是不是自由摆放"。
        // 在"按名称"下拖第一下时，落点会把整理方式切成自由摆放；
        // 如果这时候其他格子还没有位置记录，它们会被自动排布重摆一遍 —— 就是"拖一个其他都乱了"。
        // 所以不管当前是哪种布局，先把每格**现在所在的位置**读出来存好。
        var frozen: [String: NSPoint] = [:]
        let layout = collectionView.collectionViewLayout
        for (index, item) in items.enumerated() {
            let path = IndexPath(item: index, section: 0)
            guard let attributes = layout?.layoutAttributesForItem(at: path) else { continue }
            frozen[item.name] = attributes.frame.origin
        }
        guard frozen.count == items.count else { return }   // 读全了才敢用
        PlacementStore.setPositions(frozen, in: folderURL)
    }

    /// 窗口内拖拽落点 = 换位。位置要留得住就得是"自由摆放"布局，
    /// 所以顺手把整理方式切过去（⋯ 菜单里能看到勾选变化）。
    private func handleInternalMove(_ indexPath: IndexPath, to origin: NSPoint) {
        guard ViewSettings.mode == .icon else { return }   // 列表是排好的，换位没意义
        // **在落点这一刻把其他格子的位置钉住**，而不是只靠拖拽开始时那次回调：
        // 此刻布局还是"排好序"的那套，读到的就是每格现在所在的位置。
        // 钉完再切整理方式/挪格子，其他格子就有确切坐标了，不会被自动排布重摆。
        freezeFreePlacementPositions()
        if !ViewSettings.freePlacement {
            // 从"按xx整理"切到自由摆放：位置才开始有意义
            ViewSettings.arrange = .none
            for item in arrangeItems {
                item.state = (item.representedObject as? String == ArrangeMode.none.rawValue) ? .on : .off
            }
            applyLayout()
        }
        // 「贴靠网格」模式下拖完也吸一下
        var target = origin
        if ViewSettings.arrange == .snapToGrid {
            let g = ViewSettings.snapGrid
            target = NSPoint(x: (origin.x / g).rounded() * g, y: (origin.y / g).rounded() * g)
        }
        moveItem(indexPath, to: target)
    }

    private func moveItem(_ indexPath: IndexPath, to origin: NSPoint) {
        let source = items
        guard source.indices.contains(indexPath.item),
              let layout = collectionView.collectionViewLayout as? IconLayout else { return }
        layout.positions[indexPath] = origin
        layout.invalidateLayout()
        collectionView.needsDisplay = true
        PlacementStore.setPosition(origin, for: source[indexPath.item].name, in: folderURL)
    }

    @objc private func resetPlacement() {
        PlacementStore.clear(in: folderURL)
        applyLayout()
    }

    // MARK: - 网格自适应

    /// 网格/自由摆放共用的格子尺寸。
    /// 单元要比"图标 + 一圈留白"再宽一点：太窄的话长名字会被迫在词中间断开
    /// （"MagicaVoxel" 这种 11 个字符的名字，70pt 宽正好放不下）。
    func gridItemSize() -> NSSize {
        GridMetrics.itemSize(iconSide: ViewSettings.iconSize)
    }

    private func updateItemSize(force: Bool = false) {
        guard ViewSettings.mode == .icon,
              let layout = collectionView.collectionViewLayout as? IconLayout else { return }
        let size = gridItemSize()
        let side = ViewSettings.iconSize
        // 图标变小的时候**格子宽度可能一点没变**（宽度有下限 70，名字得放得下），
        // 但间距是跟着图标大小走的 —— 所以 iconSide 变了也得重排，
        // 否则拖小图标时格子之间还是原来的松紧。
        let changed = force
            || abs(side - layout.iconSide) > 0.5
            || abs(size.width - currentItemWidth) > 0.5
            || abs(size.height - currentItemHeight) > 0.5
        guard changed else { return }
        currentItemWidth = size.width
        currentItemHeight = size.height
        layout.iconSide = side
        layout.itemSize = size
        layout.invalidateLayout()
    }
}

// MARK: - 数据源

extension FolderWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let source = items
        guard source.indices.contains(indexPath.item) else {
            return collectionView.makeItem(withIdentifier: FileItemView.identifier, for: indexPath)
        }
        let item = source[indexPath.item]
        let marked = changedFolders.contains(item.url.path)

        if ViewSettings.mode == .list {
            let view = collectionView.makeItem(withIdentifier: FileRowView.identifier, for: indexPath)
            let row = view as? FileRowView
            row?.windowActive = focusActive
            row?.configure(with: item, marked: marked,
                           striped: indexPath.item % 2 == 1,
                           showFolder: false)
            return view
        }
        let view = collectionView.makeItem(withIdentifier: FileItemView.identifier, for: indexPath)
        // 只有"分组框真的在画"时才省略格子里的路径（组名已经标了来源）；
        // 自由放置等没有分组框的情况下，仍然在格子里标出来源。
        let cell = view as? FileItemView
        cell?.windowActive = focusActive
        // 分组框那套已经删了（访达也没有"把子文件夹内容平铺出来"这回事）
        cell?.configure(with: item, marked: marked, showFolder: false)
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    }
}

// MARK: - 窗口生命周期

extension FolderWindowController: NSWindowDelegate {

    func windowDidResize(_ notification: Notification) {
        // 出现/消失动画期间窗口尺寸在变，别跟着重排 —— 否则格子会看到抖动。
        // 动画结束后在 completion 里补一次。
        guard !isAnimatingFrame else { return }
        refreshLayoutForCurrentSize()
    }

    /// 按当前窗口尺寸重排一次（列表行宽 / 网格列数），并夹回屏幕可见区
    func refreshLayoutForCurrentSize() {
        if ViewSettings.mode == .list {
            resizeListLayoutToFit()   // 只改行宽，绝不 reloadData —— 否则拉窗口时列表会闪
        } else {
            updateItemSize()
            // 图标视图"一列能放几格"取决于窗口高度，窗口一变就得重算
            collectionView.collectionViewLayout?.invalidateLayout()
        }
        clampToVisibleScreen()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        setFocus(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        setFocus(false)
    }

    /// 观察焦点变化。
    ///
    /// 这个窗口**不再是** `.nonactivatingPanel`（键盘要能进来，见 AppActivation.swift），
    /// 所以"我是不是前台应用"这件事基本不可靠：实测前台一直是访达、
    /// 而 isKeyWindow 仍然是 true。因此不能只看某一个信号，
    /// 而是把下面几条都当成"失焦"的证据：
    ///   1. 窗口不再是 key（windowDidResignKey / 通知 / 轮询）
    ///   2. 别的应用被激活（NSWorkspace 的通知 + 轮询前台变化）
    /// 任何一个说"不是我了"，选中色就该退下去。
    /// 反过来"重新获得焦点"用窗口变成 key 或用户在本窗口按下鼠标来判定。
    ///
    /// 轮询只是兜底：实测这些通知在有些情况下不送达，而 0.3 秒一次
    /// 的比较开销可以忽略。
    private func observeFocusChanges() {
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setFocus(false)
            }
        }
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.setFocus(name == NSWindow.didBecomeKeyNotification)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self?.setFocus(false)
            }
        }
        // 最可靠的一条：只要鼠标按在**别的应用**上，就意味着用户离开本窗口了。
        // 本地监听（installBackgroundDrag）负责"点回来"，全局监听负责"点出去"。
        // 这一条能覆盖"前台本来就是访达、点它自己的窗口时前台没变"这种情况 ——
        // 那种情况下 isKeyWindow / 前台 PID 都不会告诉我们任何事。
        if let old = globalClickMonitor { NSEvent.removeMonitor(old) }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.setFocus(false)
        }
        lastFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollFocusState()
        }
    }

    /// 轮询兜底：窗口不是 key 了，或者前台换成了别的应用
    private func pollFocusState() {
        guard focusActive == true else { return }
        if !(window?.isKeyWindow ?? false) { setFocus(false); return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let front, front != lastFrontmostPID {
            lastFrontmostPID = front
            if front != ProcessInfo.processInfo.processIdentifier { setFocus(false) }
        }
    }

    /// 焦点状态翻转时才重画，避免无谓开销
    private func setFocus(_ active: Bool) {
        if active { lastFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard focusActive != active else { return }
        focusActive = active
        refreshSelectionAppearance()
    }

    /// 焦点变化后重画可见格子（选中色要跟着变淡/变深）。
    /// `visibleItems()` 有时会返回空（布局尚未完成），所以再兜一层：
    /// 按选中项把"已经加载出来"的格子取出来重画。
    /// 选中色是唯一跟焦点有关的状态，所以补这一层就够了。
    private func refreshSelectionAppearance() {
        var items = collectionView.visibleItems()
        for path in collectionView.selectionIndexPaths {
            guard let item = collectionView.item(at: path) else { continue }
            if !items.contains(where: { $0 === item }) { items.append(item) }
        }
        for item in items {
            if let row = item as? FileRowView {
                row.windowActive = focusActive
                row.refreshForFocusChange()
            } else if let cell = item as? FileItemView {
                cell.windowActive = focusActive
                cell.refreshForFocusChange()
            }
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        clampToVisibleScreen()
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        if let columnObserver { NotificationCenter.default.removeObserver(columnObserver) }
        columnObserver = nil
        focusTimer?.invalidate()
        focusTimer = nil
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        onClose?()
    }
}
