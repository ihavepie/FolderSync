import AppKit
import Quartz

/// 网格视图：负责接收 Finder 拖入、把内容拖出到 Finder，以及双击/右键/键盘交互。
/// 组件里的交互规则（集中写在这里，改之前先看这段）
///
/// | 手势 | 行为 |
/// |---|---|
/// | 单击图标 | 只选中 |
/// | 双击图标 | 文件夹 → 访达；文件 → 默认应用（见 onDoubleClick） |
/// | 拖动图标（>4pt） | 起拖拽会话：本窗口内落点 = 换位；拖到窗口外 = 复制 |
/// | 右键图标 | 上下文菜单（见 menuProvider） |
/// | 空白处拖动 | 框选（⇧ 追加到已有选中） |
/// | 空白处单击 | 显示桌面（判定在 FolderWindowController.isBackgroundClick） |
/// | 拖动顶部把手条 | 移动窗口（在 FolderWindowController.installBackgroundDrag 里） |
/// | Delete / Return | 移到废纸篓 / 打开 |
///
/// 注意"拖动图标"和"空白处拖动"是两个不同的手势，靠 mouseDown 时有没有命中格子区分。
final class FolderCollectionView: NSCollectionView {

    // MARK: - 对外回调

    /// 外部拖入的落盘回调
    var onDrop: (([URL], Bool) -> Void)?
    /// 双击某一格
    var onDoubleClick: ((IndexPath) -> Void)?
    /// 右键某一格，返回要弹出的菜单
    var menuProvider: ((IndexPath, NSView) -> NSMenu?)?
    /// 删除键
    var onTrash: (() -> Void)?
    /// 回车键
    var onOpen: (() -> Void)?
    /// 空格键（快速查看）：控制器用它按当前选中项填 previewURLs
    var onQuickLook: (() -> Void)?
    /// Esc：预览浮层用它收掉自己（组件窗口里没设，就走系统的 Quick Look 关闭）
    var onEscape: (() -> Void)?
    /// ⌫ 且**没有选中项**时：预览浮层用它回上一层（组件窗口里没设，⌫ 就是"没选中就什么也不做"）
    var onBack: (() -> Void)?
    /// 自由放置模式下：把某一格移动到新位置
    var onMoveItem: ((IndexPath, NSPoint) -> Void)?
    /// 快速查看要预览的条目（控制器在点菜单时设好）
    var previewURLs: [URL] = []
    /// 能不能把文件**拖进来**。
    /// 预览浮层里设成 false：那里是"看和拖出"，往里拖容易误操作（它依附父窗口，
    /// 一不小心就把文件扔进了临时看的那个目录）。
    var acceptsDrops = true

    /// 即将开始一次拖拽会话 —— 控制器用它把自由摆放的位置钉住（否则后面的图标会往前挤）
    var onDragWillBegin: (() -> Void)?
    /// 自由放置模式下位置是否有效（用来决定拖动是"移动位置"还是"拖出文件"）

    /// 某些 IndexPath 对应的 URL（拖出时用）
    var urlsForIndexPaths: (([IndexPath]) -> [URL])?
    /// 某一 IndexPath 对应的 URL
    var urlForIndexPath: ((IndexPath) -> URL?)?

    private let dropHint = NSTextField(labelWithString: "")

    // 拖出状态
    private var pendingDragIndexPath: IndexPath?
    private var pendingDragURLs: [URL] = []
    /// 按下时的位置，用来判断"是真的在拖"还是手抖（见 mouseDragged）
    private var pendingDragStart: NSPoint?
    private var dragSessionActive = false
    /// 正在拖拽的条目（窗口内落点要拿它换位）
    private var draggingIndexPath: IndexPath?

    // 自由放置：拖动某一格改位置

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // 声明本视图可以接收文件拖入
        registerForDraggedTypes([.fileURL])
        // 声明本视图作为拖拽源允许 .copy（对外）。缺了它 Finder 会拒绝放下。
        setDraggingSourceOperationMask(.copy, forLocal: false)
        setDraggingSourceOperationMask(.copy, forLocal: true)

        dropHint.translatesAutoresizingMaskIntoConstraints = false
        dropHint.alignment = .center
        dropHint.font = .systemFont(ofSize: 12, weight: .medium)
        dropHint.textColor = .white
        dropHint.wantsLayer = true
        dropHint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
        dropHint.layer?.cornerRadius = 8
        dropHint.isHidden = true
        addSubview(dropHint)

        marqueeOverlay.isHidden = true
        addSubview(marqueeOverlay)
        installMarqueeTracking()
        NSLayoutConstraint.activate([
            dropHint.centerXAnchor.constraint(equalTo: centerXAnchor),
            dropHint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            dropHint.heightAnchor.constraint(equalToConstant: 28),
            dropHint.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    /// 键盘事件只有本应用激活时才会送到这个窗口（`.nonactivatingPanel` 不会自己激活），
    /// 所以点到窗口里就显式激活一次。点空白处那条路另有"像点桌面一样"的逻辑，
    /// 两边都调这个也无害（已经激活就不做事）。
    private func activateAppForKeyboard() {
        // 注意别写 NSApp.activate(ignoringOtherApps: true) —— macOS 14 起那是空操作，
        // 见 AppActivation 的注释
        AppActivation.toFront()
    }

    // MARK: - 鼠标：框选 / 双击 / 右键 / 拖出

    /// 框选状态
    private var marqueeOrigin: NSPoint?
    /// 拖到窗口外面时视图收不到 mouseDragged，框会"冻住"，
    /// 所以用应用级监听把手势接住，并标记状态
    private var marqueeMonitor: Any?
    private var marqueeDragging = false
    private var marqueeRect: NSRect?

    override func mouseDown(with event: NSEvent) {
        // 成为第一响应者，Delete / Return 才会派发到这里。
        // 之前没人设过 —— 虽然 acceptsFirstResponder 返回 true，但压根没被点亮，
        // 所以那两个键一直是死的。
        // 更关键的一步：**激活本应用**。
        // 组件窗口是 `.nonactivatingPanel`（点它不激活应用），而键盘事件只有在本应用
        // 处于激活状态时才会派发给这个窗口 —— 结果就是"选中一个文件、按空格、空格
        // 却跑到前台应用那边去了"（实测跑到浏览器里打了个空格）。
        // 所以在真正开始交互（点到窗口里）时显式激活自己一次：
        // 之后空格（快速查看）、⌫、回车、⌘ 系列才会送到这里。
        activateAppForKeyboard()
        // 再确保"被点的这个窗口"是 key、并且这个视图是第一响应者 ——
        // 激活有可能把 key 状态给了别的窗口，那样空格还是送不到这里。
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let hit = indexPathForItem(at: point)
        // 必须在 super 之前快照选中集合：super 会把它压成单选
        let selectionBefore = selectionIndexPaths
        pendingDragIndexPath = hit
        pendingDragStart = point
        dragSessionActive = false   // 兜底：上一次拖拽若被取消且回调没到，别卡死后续拖拽

        if event.clickCount == 2, let indexPath = hit {
            pendingDragIndexPath = nil
            pendingDragURLs = []
            cancelMarquee()
            onDoubleClick?(indexPath)
            return
        }

        // 空白处按下 → 准备框选（按住 ⇧ 追加选择）
        if hit == nil {
            marqueeOrigin = point
            marqueeRect = nil
            marqueeAdditive = event.modifierFlags.contains(.shift)
            marqueeBaseSelection = selectionBefore
            pendingDragURLs = []
            if !marqueeAdditive { selectionIndexPaths = [] }
            super.mouseDown(with: event)
            return
        }

        super.mouseDown(with: event)


        // 决定这次拖拽带哪些文件：按住的那格本来就在多选里 → 拖走整批
        if selectionBefore.contains(hit!), selectionBefore.count > 1 {
            pendingDragURLs = urlsForIndexPaths?(selectionBefore.sorted()) ?? []
        } else {
            pendingDragURLs = []
        }
    }

    private let marqueeOverlay = MarqueeOverlayView()

    private var marqueeAdditive = false
    private var marqueeBaseSelection: Set<IndexPath> = []

    /// 在空白处拖动 = 框选；在原地按住不动 = 交给上层移动窗口
    override func mouseDragged(with event: NSEvent) {
        // 框选进行中
        if let origin = marqueeOrigin {
            marqueeDragging = true
            updateMarquee(from: origin, to: convert(event.locationInWindow, from: nil))
            return
        }

        // 注意：**不要**在这里"自己拖着格子走"。
        // 之前自由摆放模式下是这么干的（拖到哪格子跟到哪），代价是拖拽会话根本没机会开始
        // —— 一旦开了自由摆放，文件就再也拖不出去了（用户的"图标没法移动出去"就是它）。
        // 现在统一走拖拽会话：窗口内落点 = 换位（见 performDragOperation），
        // 拖到窗口外 = 照常复制/移动。

        guard !dragSessionActive, let indexPath = pendingDragIndexPath else {
            super.mouseDragged(with: event)
            return
        }

        // 先要求真的移动了一段距离才开始"拖出"。
        // 之前点一下手稍微一抖就起了拖拽会话，松手时如果还在窗口里，
        // 就变成往自己目录里拖入 → 复制出一份重名文件（"xxx 2.txt"）。
        if let start = pendingDragStart {
            let now = convert(event.locationInWindow, from: nil)
            if hypot(now.x - start.x, now.y - start.y) < 4 {
                return
            }
        }

        let urls: [URL]
        if !pendingDragURLs.isEmpty {
            urls = pendingDragURLs
        } else if let single = urlForIndexPath?(indexPath) {
            urls = [single]
        } else {
            urls = []
        }
        guard !urls.isEmpty else {
            super.mouseDragged(with: event)
            return
        }

        var point = convert(event.locationInWindow, from: nil)
        if !bounds.contains(point) { point = CGPoint(x: bounds.midX, y: bounds.midY) }

        let side: CGFloat = 48
        let origin = CGPoint(x: point.x - side / 2, y: point.y - side / 2)
        let icon = NSWorkspace.shared.icon(forFile: urls[0].path)
        icon.size = NSSize(width: side, height: side)

        let item = NSDraggingItem(pasteboardWriter: urls[0] as NSURL)
        item.setDraggingFrame(CGRect(origin: origin, size: CGSize(width: side, height: side)), contents: icon)

        onDragWillBegin?()
        dragSessionActive = true
        draggingIndexPath = indexPath
        pendingDragIndexPath = nil
        pendingDragURLs = []
        NSLog("[FolderSync] 开始拖出: \(urls.map { $0.lastPathComponent })")
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        marqueeDragging = false
        cancelMarquee()
        pendingDragIndexPath = nil
        pendingDragURLs = []
        super.mouseUp(with: event)
    }

    // MARK: - 框选

    /// 框选矩形交给一个独立的小视图去画。
    /// 之前是在 collectionView 自己的 draw 里画，缩小框时旧虚线会残留
    /// （重绘区域算不准）；换成子视图后，移动/隐藏由视图系统负责，不会有残影。
    private func updateMarqueeOverlay(_ rect: NSRect) {
        guard rect.width > 0.5 || rect.height > 0.5 else {
            marqueeOverlay.isHidden = true
            return
        }
        marqueeOverlay.isHidden = false
        marqueeOverlay.frame = rect
        marqueeOverlay.needsDisplay = true
    }

    private func installMarqueeTracking() {
        marqueeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.marqueeDragging, let origin = self.marqueeOrigin else { return event }
            switch event.type {
            case .leftMouseDragged:
                // 用 window 坐标换算，指针跑到窗口外也能继续跟手
                let point = self.convert(event.locationInWindow, from: nil)
                self.updateMarquee(from: origin, to: point)
                return nil
            case .leftMouseUp:
                self.marqueeDragging = false
                self.cancelMarquee()
                return event
            default:
                return event
            }
        }
    }

    /// 由外部（控制器）提供要画的分组框：[名称, 矩形]

    /// 分组框画在网格自己的 draw 里 —— 跑在下面，不影响 item 渲染，
    /// 也不会像独立浮层那样需要处理坐标系翻转。


    /// 更新选框：命中判定用「跟随指针的真实矩形」，绘制用「裁到可视区的矩形」，
    /// 两者分开就不会因为裁剪而错位（之前不跟手就是这里混在一起）
    private func updateMarquee(from origin: NSPoint, to current: NSPoint) {
        let real = NSRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                          width: abs(current.x - origin.x), height: abs(current.y - origin.y))
        let visible = real.intersection(bounds)
        marqueeRect = real
        updateMarqueeOverlay(visible)
        applyMarqueeSelection(real)
    }

    deinit {
        if let marqueeMonitor { NSEvent.removeMonitor(marqueeMonitor) }
    }

    /// 把落在框里的格子设为选中（按住 ⇧ 时叠加在原选择上）。
    /// 命中判定抽成纯函数，便于自检确定性地验证。
    private func applyMarqueeSelection(_ rect: NSRect) {
        let attributes = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
        let hits = Self.indexPaths(hitting: rect, in: attributes)
        var selected = marqueeAdditive ? marqueeBaseSelection : Set<IndexPath>()
        for indexPath in hits { selected.insert(indexPath) }
        selectionIndexPaths = selected
    }

    /// 纯函数：给定框与布局属性，算出应被选中的 index path
    static func indexPaths(hitting rect: NSRect,
                           in attributes: [NSCollectionViewLayoutAttributes]) -> [IndexPath] {
        attributes.compactMap { attribute in
            guard let indexPath = attribute.indexPath else { return nil }
            return attribute.frame.intersects(rect) ? indexPath : nil
        }
    }

    /// 自检：按给定起点/终点跑一遍框选，返回命中数与选中数。
    /// 走的是与真实鼠标完全相同的代码路径，只是绕开合成事件。
    /// 自检：反复"拉大再缩小"框，检查浮层没有残留（隐藏时 frame 必须归零）
    func runMarqueeResizeTest() -> Bool {
        layoutSubtreeIfNeeded()
        let sizes: [NSSize] = [
            NSSize(width: 900, height: 900),   // 大
            NSSize(width: 40, height: 40),     // 缩小
            NSSize(width: 900, height: 900),   // 再大
            NSSize(width: 2, height: 2),       // 很小（应隐藏）
        ]
        for size in sizes {
            let rect = NSRect(origin: .zero, size: size)
            marqueeRect = rect
            updateMarqueeOverlay(rect)
            let shown = !marqueeOverlay.isHidden
            let matches = abs(marqueeOverlay.frame.width - size.width) < 1.5
                && abs(marqueeOverlay.frame.height - size.height) < 1.5
            if size.width < 1 || size.height < 1 {
                if shown { NSLog("[FolderSync] 框选缩小后未隐藏"); return false }
            } else if !shown || !matches {
                NSLog("[FolderSync] 框选浮层尺寸不符 期望=\(size) 实际=\(marqueeOverlay.frame)")
                return false
            }
        }
        // 结束框选后必须完全收起
        let big = NSRect(x: 0, y: 0, width: 900, height: 900)
        marqueeRect = big
        updateMarqueeOverlay(big)
        cancelMarquee()
        return marqueeOverlay.isHidden && marqueeOverlay.frame == .zero
    }

    func runMarqueeSelfTest(from start: NSPoint, to end: NSPoint) -> (hits: Int, selected: Int) {
        layoutSubtreeIfNeeded()
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        marqueeAdditive = false
        marqueeBaseSelection = selectionIndexPaths
        applyMarqueeSelection(rect)
        let attributes = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
        return (Self.indexPaths(hitting: rect, in: attributes).count, selectionIndexPaths.count)
    }

    private func cancelMarquee() {
        marqueeOrigin = nil
        marqueeRect = nil
        marqueeAdditive = false
        marqueeOverlay.isHidden = true
        marqueeOverlay.frame = .zero
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point), let provider = menuProvider else {
            super.rightMouseDown(with: event)
            return
        }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        if let menu = provider(indexPath, self) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Delete / Forward Delete
            if !selectionIndexPaths.isEmpty, let onTrash { onTrash(); return }
            if let onBack { onBack(); return }
        case 36, 76: // Return / Enter
            if !selectionIndexPaths.isEmpty { onOpen?(); return }
        case 49: // 空格 = 快速查看（访达就是这个键）
            onQuickLook?()
            return
        case 53: // Esc = 关掉快速查看 / 收掉预览浮层
            if let onEscape { onEscape() } else { hideQuickLook() }
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: - 快速查看（QLPreviewPanel）

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// 空格 / 右键菜单都走这里：显示中就收掉，否则打开
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showQuickLook()
        }
    }

    func showQuickLook() {
        guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        // 本 app 是 `.accessory`：不激活的话面板成不了 key，
        // 表现就是"空格点下去什么都没发生"或者面板出来但按不动。
        AppActivation.toFront()
        panel.makeKeyAndOrderFront(nil)
    }

    func hideQuickLook() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    // MARK: - 拖入

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (items as? [URL]) ?? []
    }

    private func updateHint(for sender: NSDraggingInfo) {
        dropHint.stringValue = FileOps.wantsMove ? "移动到此处" : "复制到此处（按住 Option 移动）"
        dropHint.isHidden = false
    }

    /// 这次拖拽是不是从本窗口自己发起的（= 窗口内换位）
    private func isSelfDrag(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? FolderCollectionView) === self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops else { return [] }
        guard !fileURLs(from: sender).isEmpty else { return super.draggingEntered(sender) }
        // 本窗口内拖拽 = 换位：返回 .move，macOS 对 move **不画**那个绿色「+」
        if isSelfDrag(sender) { return .move }
        updateHint(for: sender)
        return FileOps.wantsMove ? .move : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops else { return [] }
        guard !fileURLs(from: sender).isEmpty else { return super.draggingUpdated(sender) }
        if isSelfDrag(sender) { return .move }
        updateHint(for: sender)
        return FileOps.wantsMove ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHint.isHidden = true
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHint.isHidden = true
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !fileURLs(from: sender).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrops else { return false }
        // ① 从**本窗口**拖出来的，落在窗口里 = 换位，不是"拖入文件"。
        //    之前这种情况会走 onDrop，被 ingest 当成拖入，凭空复制出一份重名文件。
        if let source = sender.draggingSource as? FolderCollectionView, source === self,
           let indexPath = draggingIndexPath {
            dropHint.isHidden = true
            let point = convert(sender.draggingLocation, from: nil)
            let size = collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame.size
                ?? CGSize(width: 96, height: 78)
            onMoveItem?(indexPath, NSPoint(x: point.x - size.width / 2,
                                           y: point.y - size.height / 2))
            return true
        }

        // ② 从别处（访达等）拖进来的，才是真的落盘
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        dropHint.isHidden = true
        onDrop?(urls, FileOps.wantsMove)
        return true
    }
}

// MARK: - 作为拖拽源

extension FolderCollectionView {

    /// 允许的操作：对外是复制。这是 NSCollectionView 已有的方法，必须 override。
    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 源只声明 .copy。**不能因为"在应用内"就只声明 .move** ——
        // 源声明的操作集合必须和落点返回的操作对得上，否则整次拖放会被拒绝：
        // 表现就是"窗口内拖了没反应" + "拖不出去"（踩过）。
        // 不画"复制"角标这件事交给**落点**：落点返回 .move 时 macOS 不画角标，
        // 只有 .copy 才画那个绿色「+」。见 draggingEntered / draggingUpdated。
        _ = context
        return .copy
    }

    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    /// 拖拽会话结束（成功落盘、松开取消、按 Esc 取消都算）。
    /// **必须复位 dragSessionActive**：之前只置 true 从不清零，
    /// 于是"拖出去过一次之后，就再也拖不出去了" —— 手感和"拖一次就废"一样。
    override func draggingSession(_ session: NSDraggingSession,
                                  endedAt screenPoint: NSPoint,
                                  operation: NSDragOperation) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        dragSessionActive = false
        draggingIndexPath = nil
        pendingDragIndexPath = nil
        pendingDragURLs = []
        pendingDragStart = nil
    }
}

extension FolderCollectionView: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
}
