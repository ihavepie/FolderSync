import Foundation
import CoreServices

/// 用 FSEvents 递归监听一个目录，任何变化都会合并后回调（debounce）。
/// 这是"文件夹变了，窗口实时更新"的核心。
///
/// 关键设计：`FSEventStreamCreate` 内部会走 `watch_path`（和 fseventsd 通信），
/// 在某些情况下会**卡住很久**。所以创建/启动一律放到私有队列上执行，
/// 绝不占用主线程；万一创建迟迟不返回，还有轮询兜底，保证功能不"哑掉"。
final class DirectoryWatcher {

    private let path: String
    private let onChange: ([String]) -> Void
    /// 只用于 FSEventStream 的创建/启动/回调。它可能被 watch_path 长时间阻塞，
    /// 所以绝不和防抖、轮询共用队列，否则一卡全卡。
    private let streamQueue = DispatchQueue(label: "foldersync.fsevents")
    /// 防抖与轮询兜底
    private let workQueue = DispatchQueue(label: "foldersync.watcher")

    private var stream: FSEventStreamRef?
    private var pendingWorkItem: DispatchWorkItem?
    /// 本轮防抖窗口内发生变化的子路径
    private var pendingPaths: Set<String> = []
    /// 防止已停止的 watcher 再回调
    private var stopped = false

    /// 轮询兜底定时器（FSEvents 不可用时）
    private var pollTimer: DispatchSourceTimer?
    private var lastSnapshot: [String] = []

    private let debounce: TimeInterval = 0.15
    /// 超过这个时间 FSEvents 还没就绪就直接切轮询，不等它
    private let streamDeadline: TimeInterval = 1.2
    private let pollInterval: TimeInterval = 1.0

    /// 串行化"开始创建 / 创建完成"，避免截止时间与完成事件竞态
    private let stateQueue = DispatchQueue(label: "foldersync.watcher.state")
    private var streamCreationStarted = false

    init(path: String, onChange: @escaping ([String]) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit {
        // 只释放资源，不做需要等待队列的操作（deinit 可能就在回调队列上执行）
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        pollTimer?.cancel()
    }

    // MARK: - 启动 / 停止

    func start() {
        stopped = false
        stateQueue.sync { streamCreationStarted = true }
        streamQueue.async { [weak self] in
            guard let self, !self.stopped, self.stream == nil else { return }
            self.createStreamOnQueue()
        }
        // 截止时间在 workQueue 上等：FSEvents 迟迟不就绪也不会拖住任何东西
        workQueue.asyncAfter(deadline: .now() + streamDeadline) { [weak self] in
            guard let self, !self.stopped else { return }
            let ready = self.stateQueue.sync { self.stream != nil }
            if !ready {
                self.stateQueue.sync { self.streamCreationStarted = false }
                self.armPolling()
            }
        }
    }

    func stop() {
        stopped = true
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingPaths.removeAll()
        endPolling()
        streamQueue.async { [weak self] in
            guard let self, let s = self.stream else { return }
            self.stream = nil
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    // MARK: - FSEvents（全部在私有队列上）

    private func createStreamOnQueue() {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            guard !watcher.stopped else { return }
            // 带 kFSEventStreamCreateFlagFileEvents 时，eventPaths 是 C 字符串数组
            // (char **)，不是 CFArray，必须按指针数组读取，否则会崩。
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var changed: [String] = []
            changed.reserveCapacity(numEvents)
            for index in 0..<numEvents {
                if let cString = paths[index] {
                    changed.append(String(cString: cString))
                }
            }
            watcher.scheduleReload(paths: changed)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags
        ) else {
            NSLog("[FolderSync] FSEventStreamCreate failed for \(path)")
            return
        }

        // 创建期间可能已经被 stop 了
        if stopped {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }

        FSEventStreamSetDispatchQueue(s, streamQueue)
        FSEventStreamStart(s)
        stream = s
        // 已经起来了，把轮询关掉
        workQueue.async { [weak self] in self?.endPolling() }
        NSLog("[FolderSync] FSEvents 已启动: \(path)")
    }

    // MARK: - 轮询兜底

    /// FSEvents 没能按时就绪时接管刷新。幂等，可重复调用。
    private func armPolling() {
        guard !stopped, pollTimer == nil else { return }
        NSLog("[FolderSync] FSEvents 未按时就绪，改用轮询: \(path)")

        lastSnapshot = snapshot()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = self.snapshot()
            if now != self.lastSnapshot {
                self.lastSnapshot = now
                self.scheduleReload(paths: [self.path])
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func endPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func snapshot() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path).sorted()) ?? []
    }

    // MARK: - 防抖

    private func scheduleReload(paths: [String]) {
        for p in paths { pendingPaths.insert(p) }
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let changed = self.pendingPaths
            self.pendingPaths = []
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.onChange(Array(changed))
            }
        }
        pendingWorkItem = item
        workQueue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
