import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private static let foldersKey = "watchedFolders"
    private static let levelModeKey = "windowLevelMode"

    /// 当前窗口层级偏好（所有窗口统一）
    private var levelMode: WindowLevelMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.levelModeKey) ?? ""
            return WindowLevelMode(rawValue: raw) ?? .desktop
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.levelModeKey) }
    }
    private var controllers: [FolderWindowController] = []

    /// 顶部状态栏的那颗图标：关掉所有组件窗口之后，进程靠它继续活着、也靠它再叫回来
    private var statusItem: NSStatusItem?
    /// ⌘ 键监听的 token
    private var keyMonitor: Any?

    /// 由 main.swift 从 --folder 参数注入
    var startupFolders: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        installStatusItem()
        installKeyMonitor()
        restoreWindows()
    }

    // MARK: - ⌘ 快捷键

    /// 应用级监听。
    /// 这个 app 是 `.accessory`（不进 Dock、不激活），所以**主菜单里的快捷键不会被派发** ——
    /// 文档里写的 ⌘D / ⌘O / ⌘W 之前其实都是死的。这里自己接住并路由：
    /// 窗口作用域的键（⌘W / ⌘[ / ⌘R / ⌘N）交给"当前 key 窗口"的控制器，
    /// 应用级的（⌘O / ⌘D）直接在这里做。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEquivalent(event) ? nil : event
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              !key.isEmpty else { return false }

        if let controller = controllers.first(where: { $0.window?.isKeyWindow == true }),
           controller.handleCommandKey(key) {
            return true
        }
        switch key {
        case "o": openNewWindow(); return true
        case "d": openDesktopWindow(); return true
        default: return false
        }
    }

    // MARK: - 顶部状态栏

    /// 装一颗状态栏图标。
    /// 配合 main.swift 里的 `.accessory`：不进 Dock、不占 ⌘Tab，
    /// 只留顶部这一颗；窗口全关了进程也还在，点它就能把组件叫回来或者真正退出。
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "folder", accessibilityDescription: "FolderSync")
        image?.isTemplate = true          // 跟着浅色/深色菜单栏自动变色
        item.button?.image = image
        item.button?.toolTip = "FolderSync"
        item.menu = NSMenu()
        item.menu?.delegate = self        // 每次弹出前重建，勾选状态才是最新的
        statusItem = item
    }

    @objc private func showAllComponents() {
        guard !controllers.isEmpty else { openDesktopWindow(); return }
        for controller in controllers {
            controller.showWindow(nil)
            controller.window?.orderFrontRegardless()
        }
    }

    @objc private func hideAllComponents() {
        for controller in controllers { controller.window?.orderOut(nil) }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    /// 弹出系统授权提示（辅助功能）。有了它，"点空白处"才会触发系统自己的
    /// 「显示桌面」—— 窗口滑到一边、再点滑回来，而不是我们手动隐藏/恢复窗口。
    @objc private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewWindow() }
        return true
    }

    // Finder 里"用本应用打开"一个文件夹
    func application(_ sender: NSApplication, open urls: [URL]) {
        var opened = false
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                NSWorkspace.shared.open(url)
                continue
            }
            _ = openWindow(for: url)
            opened = true
        }
        if opened { persist() }
    }

    // MARK: - 窗口管理

    /// 打开子文件夹。现在**等同于新建一个普通窗口** ——
    /// 之前的"紧凑浮动小窗"在嵌套场景下拖拽定位有问题，索性统一成普通窗口。
    @discardableResult
    func openSatelliteWindow(for url: URL, beside parent: NSWindow?) -> FolderWindowController {
        openWindow(for: url)
    }

    func openWindow(for url: URL) -> FolderWindowController {
        if let existing = controllers.first(where: { $0.folderURL.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }

        let controller = FolderWindowController(folderURL: url, levelMode: levelMode)
        controller.onClose = { [weak self] in self?.pruneAndPersist() }
        controller.onOpenAnotherWindow = { [weak self] in self?.openNewWindow() }
        // 预览浮层上点「钉住」：把这个目录变成常驻组件窗口（位置/大小会被记住、
        // 变成可写、能往里拖）—— 这就是"预览 → 固定"那条连续动作的落点。
        controller.onOpenFolderPermanently = { [weak self] url in
            guard let self else { return }
            _ = self.openWindow(for: url)
            self.persist()
        }
        controller.onLevelModeChanged = { [weak self] mode in
            self?.levelMode = mode
            self?.applyLevelModeToAll(mode)
        }
        controllers.append(controller)

        if let window = controller.window {
            // 让窗口在打开时自动出现在合适的位置：**尽量不和已有窗口重叠**。
            var frame = window.frame
            frame.origin = nonOverlappingOrigin(for: frame.size, on: window.screen ?? NSScreen.main)
            window.setFrame(frame, display: false)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.animateIn()
        return controller
    }

    /// 给新窗口找一个**不压住已有窗口**的位置。
    ///
    /// 之前的做法是层叠偏移（每个新窗口右下角挪 26pt），开着两个窗口时后开的那个
    /// 一定会盖住前一个 —— 而这些东西是"桌面组件"，盖住就没法同时用了。
    /// 现在按"窗口大小 + 间距"在屏幕可见区里扫格子，取第一个和现有窗口都不相交的位置；
    /// 真的摆满了（屏幕放不下）才退回层叠偏移。
    private func nonOverlappingOrigin(for size: CGSize, on screen: NSScreen?) -> NSPoint {
        guard let area = (screen ?? NSScreen.main)?.visibleFrame else { return .zero }
        let gap: CGFloat = 12
        let existing = controllers.compactMap { $0.window?.frame }

        var y = area.maxY - size.height
        while y >= area.minY {
            var x = area.minX
            while x + size.width <= area.maxX {
                let candidate = NSRect(x: x, y: y, width: size.width, height: size.height)
                let padded = candidate.insetBy(dx: -gap / 2, dy: -gap / 2)
                if !existing.contains(where: { $0.intersects(padded) }) {
                    return candidate.origin
                }
                x += size.width + gap
            }
            y -= size.height + gap
        }
        // 摆不下了：退回层叠，至少别完全重合
        let offset = CGFloat(controllers.count % 8) * 26
        return NSPoint(x: area.minX + offset,
                       y: max(area.minY, area.maxY - size.height - offset))
    }

    /// 把所有窗口切到同一层级
    func applyLevelModeToAll(_ mode: WindowLevelMode) {
        levelMode = mode
        for controller in controllers { controller.applyLevelMode(mode) }
    }

    @objc func setLevelNormal() { applyLevelModeToAll(.normal) }
    @objc func setLevelDesktop() { applyLevelModeToAll(.desktop) }
    @objc func setLevelFloating() { applyLevelModeToAll(.floating) }

    @objc func openNewWindow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要在窗口中实时展示的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = openWindow(for: url)
        persist()
    }

    @objc func cycleLevelMode() {
        let all = WindowLevelMode.allCases
        let next = all[(all.firstIndex(of: levelMode).map { $0 + 1 } ?? 0) % all.count]
        applyLevelModeToAll(next)
    }

    @objc func openDesktopWindow() {
        _ = openWindow(for: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
        persist()
    }

    private func pruneAndPersist() {
        controllers.removeAll { $0.window?.isVisible == false && $0.window?.isMiniaturized == false }
        persist()
    }

    // MARK: - 状态栏菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()

        let showItem = NSMenuItem(title: "显示全部组件", action: #selector(showAllComponents), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let hideItem = NSMenuItem(title: "隐藏全部组件", action: #selector(hideAllComponents), keyEquivalent: "")
        hideItem.target = self
        hideItem.isEnabled = !controllers.isEmpty
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let desktopItem = NSMenuItem(title: "打开桌面窗口", action: #selector(openDesktopWindow), keyEquivalent: "d")
        desktopItem.target = self
        menu.addItem(desktopItem)

        let newItem = NSMenuItem(title: "打开文件夹…", action: #selector(openNewWindow), keyEquivalent: "o")
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        let levelParent = NSMenuItem(title: "窗口层级", action: nil, keyEquivalent: "")
        let levelMenu = NSMenu(title: "窗口层级")
        for mode in WindowLevelMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickLevelFromStatus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == levelMode) ? .on : .off
            levelMenu.addItem(item)
        }
        levelParent.submenu = levelMenu
        menu.addItem(levelParent)

        // 常用文件夹：不用每次弹面板去选
        let placesParent = NSMenuItem(title: "常用文件夹", action: nil, keyEquivalent: "")
        let placesMenu = NSMenu(title: "常用文件夹")
        for controller in controllers {
            let title = (controller.window?.title).flatMap { $0.isEmpty ? nil : $0 }
                ?? controller.folderURL.lastPathComponent
            let item = NSMenuItem(title: title, action: #selector(openPlaceFromStatus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller.folderURL
            placesMenu.addItem(item)
        }
        if !controllers.isEmpty { placesMenu.addItem(.separator()) }
        for place in Self.commonPlaces() {
            let item = NSMenuItem(title: place.title, action: #selector(openPlaceFromStatus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = place.url
            placesMenu.addItem(item)
        }
        placesMenu.addItem(.separator())
        let chooseItem = NSMenuItem(title: "选择文件夹…", action: #selector(openNewWindow), keyEquivalent: "o")
        chooseItem.target = self
        placesMenu.addItem(chooseItem)
        placesParent.submenu = placesMenu
        menu.addItem(placesParent)

        menu.addItem(.separator())

        // 有窗口读不了目录（TCC 没授权）时，直接给一键入口 ——
        // 否则用户只看到"这个文件夹是空的/锁死的"，不知道去哪儿开。
        if controllers.contains(where: { $0.accessDenied }) {
            let folders = NSMenuItem(title: "打开「文件与文件夹」权限设置…",
                                     action: #selector(openFilesAndFoldersSettings), keyEquivalent: "")
            folders.target = self
            menu.addItem(folders)

            let fda = NSMenuItem(title: "打开「完全磁盘访问权限」设置…",
                                 action: #selector(openFullDiskAccessSettings), keyEquivalent: "")
            fda.target = self
            menu.addItem(fda)
            menu.addItem(.separator())
        }

        // 这里原来有「图标间距 ▸」（4 档）。删掉了：间距现在跟着图标大小算
        // （见 GridMetrics.clearance），不需要手动挑档位，少一个要想的设置项。

        // 「点空白处显示桌面」想用系统那套动画，需要辅助功能权限；
        // 没有权限时只能退回"隐藏/恢复其他应用"，手感差一截。
        if !AXIsProcessTrusted() {
            let permItem = NSMenuItem(title: "启用系统「显示桌面」动画…",
                                      action: #selector(requestAccessibilityPermission),
                                      keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
            menu.addItem(.separator())
        }

        // 构建时间：一眼看出跑的是不是最新编译的那个
        if let built = Bundle.main.object(forInfoDictionaryKey: "FolderSyncBuildTime") as? String {
            let stamp = NSMenuItem(title: "构建于 \(built)", action: nil, keyEquivalent: "")
            stamp.isEnabled = false
            menu.addItem(stamp)
            menu.addItem(.separator())
        }

        let quitItem = NSMenuItem(title: "退出 FolderSync", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// 状态栏「常用文件夹」里除了"当前开着的窗口"，再固定放几个常去的地方
    private static func commonPlaces() -> [(title: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var out: [(String, URL)] = []
        let candidates: [(String, URL)] = [
            ("桌面", home.appendingPathComponent("Desktop")),
            ("下载", home.appendingPathComponent("Downloads")),
            ("文稿", home.appendingPathComponent("Documents")),
            ("默认目录", defaultFolder()),
        ]
        var seen = Set<String>()
        for (title, url) in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard seen.insert(url.path).inserted else { continue }
            out.append((title, url))
        }
        return out
    }

    @objc private func openPlaceFromStatus(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = openWindow(for: url)
        persist()
    }

    @objc private func pickLevelFromStatus(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowLevelMode(rawValue: raw) else { return }
        applyLevelModeToAll(mode)
    }

    /// 打开「隐私与安全性 → 文件与文件夹」。桌面 / 文稿 / 下载 / 外置盘 / 网络卷
    /// 这些受保护目录，授权就在这一栏里。
    @objc private func openFilesAndFoldersSettings() {
        openPrivacyPane("Privacy_FilesAndFolders")
    }

    /// 打开「隐私与安全性 → 完全磁盘访问权限」。
    /// 想直接看 ~/Library、别块盘的任意目录这类地方，需要的是这个。
    @objc private func openFullDiskAccessSettings() {
        openPrivacyPane("Privacy_AllFiles")
    }

    private func openPrivacyPane(_ anchor: String) {
        // 新系统（Ventura+）用的是新 URL，旧的那个作为兜底
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - 持久化

    private func persist() {
        let paths = controllers.map { $0.folderURL.path }
        UserDefaults.standard.set(paths, forKey: Self.foldersKey)
    }

    private func restoreWindows() {
        let fm = FileManager.default

        // 命令行指定优先
        if !startupFolders.isEmpty {
            let valid = startupFolders.filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            if !valid.isEmpty {
                for url in valid { _ = openWindow(for: url) }
                persist()
                return
            }
        }

        let saved = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []

        var urls: [URL] = saved.compactMap { path in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }

        if urls.isEmpty {
            urls = [Self.defaultFolder()]
        }

        for url in urls { _ = openWindow(for: url) }
        persist()
    }

    /// 首次打开（还没有任何已保存的目录）时用哪个目录。
    ///
    /// 不用 `~/Desktop`：那个要「桌面文件夹」授权，而本 app 是 ad-hoc 签名，
    /// **每次重新编译签名都会变、授权都会被 macOS 收回**，于是每次都要重新点弹窗。
    /// 改成跟着 app 自己的安装位置走 —— app 装在哪块盘上，就用那块盘的 Applications，
    /// 外置盘上的目录不需要任何授权。
    /// app 在启动盘上（或者盘上没有 Applications）时，退回 ~/Desktop。
    static func defaultFolder() -> URL {
        let fm = FileManager.default
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        var isDir: ObjCBool = false

        guard let volume = try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeURLKey]).volume,
              volume.path != "/" else { return desktop }      // 在启动盘上就照旧

        let apps = volume.appendingPathComponent("Applications")
        if fm.fileExists(atPath: apps.path, isDirectory: &isDir), isDir.boolValue { return apps }
        return volume
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 FolderSync", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 FolderSync", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 FolderSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开桌面窗口", action: #selector(AppDelegate.openDesktopWindow), keyEquivalent: "d").target = self
        fileMenu.addItem(withTitle: "打开文件夹…", action: #selector(AppDelegate.openNewWindow), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())

        // 窗口层级
        let levelParent = NSMenuItem(title: "窗口层级", action: nil, keyEquivalent: "")
        let levelMenu = NSMenu(title: "窗口层级")
        levelMenu.addItem(withTitle: "普通窗口", action: #selector(AppDelegate.setLevelNormal), keyEquivalent: "").target = self
        levelMenu.addItem(withTitle: "挂在桌面上", action: #selector(AppDelegate.setLevelDesktop), keyEquivalent: "").target = self
        levelMenu.addItem(withTitle: "浮动在最上层", action: #selector(AppDelegate.setLevelFloating), keyEquivalent: "").target = self
        levelParent.submenu = levelMenu
        fileMenu.addItem(levelParent)

        let cycleItem = NSMenuItem(title: "循环切换层级", action: #selector(AppDelegate.cycleLevelMode), keyEquivalent: "t")
        cycleItem.keyEquivalentModifierMask = [.command, .shift]
        cycleItem.target = self
        fileMenu.addItem(cycleItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "移到废纸篓", action: #selector(FolderWindowController.trashSelection), keyEquivalent: "\u{8}")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
