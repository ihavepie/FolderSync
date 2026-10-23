import AppKit
import QuickLookThumbnailing

/// 真·缩略图（图片/视频/PDF 显示内容，而不是通用文档图标）。
///
/// 背景：以前图标一律用 `NSWorkspace.icon(forFile:)` —— 那是"文件类型图标"，
/// 一个塞满照片的文件夹里会是一排一模一样的图标。访达图标视图里显示的是**内容缩略图**，
/// 靠系统的 Quick Look 缩略图生成器（`QLThumbnailGenerator`）做。
///
/// 三条设计原则：
///
/// 1. **只给"真的要显示的格子"生成**：请求由 `FileItemView.configure` 发起，
///    而 NSCollectionView 只会配置可见（+复用）的格子 —— 于是天然是懒加载，
///    1000 个文件的目录不会一上来就生成 1000 张缩略图。
/// 2. **先图标、后缩略图**：格子先用系统图标显示（立刻可见），缩略图生成好了再替换，
///    不会为了等缩略图而白屏。
/// 3. **带缓存的异步**：缓存键 = 路径 + 修改时间 + 大小（改了文件自然失效）；
///    生成在受限并发队列上，回主线程设置图片，并核对"这个格子现在还是不是这个文件"
///    （复用会把它换成别的文件，不能张冠李戴）。
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []          // 简单的 LRU：超上限就丢最旧的
    private var inFlight: Set<String> = []
    private let maxEntries = 400

    private let queue = DispatchQueue(label: "FolderSync.thumbnails", qos: .utility,
                                      attributes: .concurrent)
    /// 同时只跑这么多：缩略图生成会拉起 QuickLook 服务，太多会互相拖慢
    private let semaphore = DispatchSemaphore(value: 3)

    private init() {}

    /// 缓存键：路径 + 修改时间 + 大小（文件改了，键就变了，自然重新生成）
    private func key(for url: URL, side: CGFloat) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)|\(stamp)|\(size)|\(Int(side))"
    }

    /// 已经有的（同步，用来避免"先闪一下图标再变缩略图"）
    func cached(for url: URL, side: CGFloat) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key(for: url, side: side)]
    }

    /// 取缩略图：有缓存直接回调，没有就异步生成。回调**不保证**在哪个线程，调用方自己回主线程。
    func thumbnail(for url: URL, side: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = key(for: url, side: side)

        lock.lock()
        if let hit = cache[cacheKey] {
            lock.unlock()
            completion(hit)
            return
        }
        if inFlight.contains(cacheKey) {          // 同一张已经在生成，别重复排队
            lock.unlock()
            completion(nil)
            return
        }
        inFlight.insert(cacheKey)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }

            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: NSSize(width: side, height: side),
                scale: scale,
                representationTypes: .thumbnail
            )
            var produced: NSImage?
            let done = DispatchSemaphore(value: 0)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                if let cg = representation?.cgImage {
                    produced = NSImage(cgImage: cg, size: NSSize(width: side, height: side))
                }
                done.signal()
            }
            // 生成器是回调式的，这里等它回来（我们已经在并发队列上，不会卡主线程）
            _ = done.wait(timeout: .now() + 8)

            self.lock.lock()
            self.inFlight.remove(cacheKey)
            if let image = produced {
                self.cache[cacheKey] = image
                self.order.append(cacheKey)
                while self.order.count > self.maxEntries {
                    let oldest = self.order.removeFirst()
                    self.cache.removeValue(forKey: oldest)
                }
            }
            self.lock.unlock()

            completion(produced)
        }
    }
}
