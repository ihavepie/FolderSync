import AppKit

// 可选：把刷新事件写入文件，用于验证"文件夹变了 → 窗口实时更新"这条链路
if let tracePath = ProcessInfo.processInfo.environment["FOLDERSYNC_TRACE"] {
    ReloadTrace.path = tracePath
}

// CLI 自检模式：直接调用与拖拽落盘完全相同的代码路径
// 用法: FolderSync --ingest-test <目标目录> [--move] <源1> <源2> ...
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--ingest-test") {
    let move = arguments.contains("--move")
    let rest = arguments[(index + 1)...].filter { $0 != "--move" }
    guard let destinationPath = rest.first else {
        FileHandle.standardError.write("用法: FolderSync --ingest-test <目标目录> [--move] <源...>\n".data(using: .utf8)!)
        exit(2)
    }
    let destination = URL(fileURLWithPath: destinationPath)
    let sources = rest.dropFirst().map { URL(fileURLWithPath: $0) }
    let result = FileOps.ingest(urls: Array(sources), into: destination, move: move)
    print("copied=\(result.copied) moved=\(result.moved) skipped=\(result.skipped)")
    print("summary=\(result.summary)")
    if let error = result.errorMessage { print("error=\(error)") }
    exit(result.skipped == 0 ? 0 : 1)
}

// 启动时直接绑定指定目录（便于测试/脚本化）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory：不进 Dock、不占 ⌘Tab —— 这个 app 的存在感放在顶部状态栏那一颗图标上。
// 关掉所有组件窗口进程也还在（见 AppDelegate.installStatusItem）。
app.setActivationPolicy(.accessory)

var startupFolders: [URL] = []
var i = 1
while i < arguments.count {
    if arguments[i] == "--folder", i + 1 < arguments.count {
        startupFolders.append(URL(fileURLWithPath: arguments[i + 1]))
        i += 2
    } else {
        i += 1
    }
}
delegate.startupFolders = startupFolders

AppActivation.toFront()
// 自检模式：验证"窗口不会跑出屏幕"
// 用法: FolderSync --clamptest <目录>
if let index = arguments.firstIndex(of: "--clamptest"), index + 1 < arguments.count {
    let dir = URL(fileURLWithPath: arguments[index + 1])
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = FolderWindowController(folderURL: dir, levelMode: .desktop)
    guard let window = controller.window else { print("NO_WINDOW"); exit(1) }
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    guard let screen = window.screen ?? NSScreen.main else { print("NO_SCREEN"); exit(1) }
    let visible = screen.visibleFrame

    var allOK = true
    // 四种越界情形：右、上、左、下
    let outs: [(String, CGPoint)] = [
        ("右上角外", CGPoint(x: visible.maxX + 800, y: visible.maxY + 600)),
        ("左下角外", CGPoint(x: visible.minX - 900, y: visible.minY - 700)),
    ]
    for (label, origin) in outs {
        window.setFrameOrigin(origin)
        let before = window.frame
        controller.testClampToScreen()
        let after = window.frame
        let inside = visible.contains(after) || (after.minX >= visible.minX - 0.5 && after.maxX <= visible.maxX + 0.5
                     && after.minY >= visible.minY - 0.5 && after.maxY <= visible.maxY + 0.5)
        print("\(label): 挪到 \(Int(before.minX)),\(Int(before.minY)) → clamp 后 \(Int(after.minX)),\(Int(after.minY)) 可见区=\(Int(visible.minX)),\(Int(visible.minY)),\(Int(visible.width))x\(Int(visible.height)) 在屏内=\(inside)")
        if !inside { allOK = false }
    }
    print(allOK ? "CLAMPTEST_OK" : "CLAMPTEST_FAIL")

    // 吸附自检：给定可见区 0,0,2560,1415，窗口 640x460，网格 20，容差 12
    let snapVisible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
    let winSize = CGSize(width: 640, height: 460)
    let cases: [(String, CGPoint, CGPoint)] = [
        // 期望值由独立实现（Python 同逻辑）算出，避免手算错
        ("贴左边(差5)",       CGPoint(x: 5, y: 600),   CGPoint(x: 0, y: 600)),
        ("贴右边(差8)",       CGPoint(x: 1912, y: 600), CGPoint(x: 1920, y: 600)),
        ("贴底边(差4)",       CGPoint(x: 700, y: 4),    CGPoint(x: 700, y: 0)),
        ("贴顶边(差6)",       CGPoint(x: 700, y: 949),  CGPoint(x: 700, y: 955)),
        ("网格(偏3)",         CGPoint(x: 903, y: 503),  CGPoint(x: 900, y: 500)),
        ("网格(偏7/偏7)",     CGPoint(x: 907, y: 707),  CGPoint(x: 900, y: 700)),
        ("网格(偏13→吸到近线)", CGPoint(x: 913, y: 713), CGPoint(x: 920, y: 720)),
    ]
    var snapOK = true
    print("--- 吸附自检 ---")
    for (label, input, expected) in cases {
        let got = FolderWindowController.snapped(input, visible: snapVisible, size: winSize,
                                                 tolerance: 12, grid: 20)
        let pass = abs(got.x - expected.x) < 0.5 && abs(got.y - expected.y) < 0.5
        if !pass { snapOK = false }
        print("  \(pass ? "✓" : "✗") \(label): \(Int(input.x)),\(Int(input.y)) → \(Int(got.x)),\(Int(got.y)) 期望 \(Int(expected.x)),\(Int(expected.y))")
    }
    print(snapOK ? "SNAPTEST_OK" : "SNAPTEST_FAIL")

    // 「回到上一级」的上限自检：主目录 = 当前目录所在的卷宗根
    print("--- 主目录（回到上一级的上限）自检 ---")
    let rootCases: [(String, Bool)] = [
        ("/Volumes/ExampleDisk/Applications", true),   // 外置盘里：还能退
        ("/Volumes/ExampleDisk/Software/FolderSync", true),
        ("/Volumes/ExampleDisk", false),               // 已经是盘根：不许再退到 /
        ("/Users", true),
        ("/", false),
    ]
    var rootOK = true
    for (path, expected) in rootCases {
        let got = FolderWindowController.canGoUp(from: URL(fileURLWithPath: path))
        if got != expected { rootOK = false }
        print("  \(got == expected ? "✓" : "✗") \(path) → 可退=\(got) 期望=\(expected)")
    }
    print(rootOK ? "ROOTTEST_OK" : "ROOTTEST_FAIL")
    print("首次启动默认目录 = \(AppDelegate.defaultFolder().path)")

    // 标题路径的缩写自检
    print("--- 标题路径缩写自检 ---")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let pathCases: [(String, String)] = [
        ("/Volumes/ExampleDisk", "/"),
        ("/Volumes/ExampleDisk/Applications", "/Applications"),
        ("/Volumes/ExampleDisk/Project/FolderSync/Sources", "/Project/FolderSync/Sources"),   // 3 段，不用省略
        ("/Volumes/ExampleDisk/Project/FolderSync/Sources/Sub", "/Project/…/Sources/Sub"),     // 4 段，从中间省略
        ("\(home)/Desktop", "~/Desktop"),
        ("/Users", "/Users"),
    ]
    var pathOK = true
    for (input, expected) in pathCases {
        let got = FolderWindowController.abbreviatedPath(URL(fileURLWithPath: input))
        if got != expected { pathOK = false }
        print("  \(got == expected ? "✓" : "✗") \(input) → \(got) 期望 \(expected)")
    }
    print(pathOK ? "PATHTEST_OK" : "PATHTEST_FAIL")

    // 整理方式自检：访达那 6 项到"自由摆放 / 排序键"的映射
    print("--- 整理方式自检 ---")
    let arrangeCases: [(ArrangeMode, Bool, SortMode?)] = [
        (.none, true, nil),
        (.snapToGrid, true, nil),
        (.byName, false, .name),
        (.byDate, false, .dateModified),
        (.bySize, false, .size),
        (.byKind, false, .kind),
    ]
    var arrangeOK = ArrangeMode.allCases.count == arrangeCases.count
    for (mode, free, sort) in arrangeCases {
        let ok = mode.isFree == free && mode.sortMode == sort
        if !ok { arrangeOK = false }
        print("  \(ok ? "✓" : "✗") \(mode.title) → 自由摆放=\(mode.isFree) 排序=\(mode.sortMode?.title ?? "无")")
    }
    print(arrangeOK ? "ARRANGETEST_OK" : "ARRANGETEST_FAIL")
    // 附带检查浮层按钮是不是正圆
    // 注意：这里量到的是布局完成前的 frame，不准。
    // 真实尺寸要用 AX 在运行中的应用里量（实测 26×26 正方形）。
    if let (size, _) = controller.testButtonGeometry() {
        print("按钮预布局 frame=\(size)（仅供参考；实际以 AX 量为准）")
    }
    exit(allOK ? 0 : 1)
}

// 自检模式：确定性地验证框选命中逻辑（走真实代码路径，不依赖合成鼠标事件）
// 用法: FolderSync --selftest <目录>
if let index = arguments.firstIndex(of: "--selftest"), index + 1 < arguments.count {
    let dir = URL(fileURLWithPath: arguments[index + 1])
    // 自检必须与用户偏好无关：复位会影响布局/枚举的开关。
    // 注意也要复位 viewMode —— 列表模式下第一行从 y=0 开始，
    // "空白处"的判定会和网格模式不同（之前漏了这一条，自检偶发失败）。
    ViewSettings.ephemeral = true    // 自检不能改用户的偏好
    ViewSettings.freePlacement = false
    ViewSettings.mode = .icon
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = FolderWindowController(folderURL: dir, levelMode: .normal)
    guard let window = controller.window else { print("NO_WINDOW"); exit(1) }
    window.setFrame(NSRect(x: 0, y: 0, width: 640, height: 460), display: false)
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))

    let view = controller.marqueeTestView
    let count = controller.testItemCount
    print("目录项目数: \(count)")
    let full = view.runMarqueeSelfTest(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 1000, y: 1000))
    print("全选测试: 命中=\(full.hits) 选中=\(full.selected) 期望=\(count)")
    let none = view.runMarqueeSelfTest(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 1, y: 1))
    print("空白测试: 命中=\(none.hits) 选中=\(none.selected) 期望=0")
    let resizeOK = view.runMarqueeResizeTest()
    print("框选缩放残留测试: \(resizeOK ? "无残留" : "有残留")")
    let ok = (full.hits == count && full.selected == count && none.hits == 0 && none.selected == 0 && resizeOK)
    print(ok ? "SELFTEST_OK" : "SELFTEST_FAIL")
    exit(ok ? 0 : 1)
}


app.run()
