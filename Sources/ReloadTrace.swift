import Foundation

/// 刷新链路追踪：把每次 reload 的时间戳和内容写进文件，
/// 用来客观验证"磁盘变了 → 窗口内容变了"真的发生了。
enum ReloadTrace {
    static var path: String?

    static func record(folder: String, items: [String]) {
        note("reload folder=\(folder) count=\(items.count) items=\(items.joined(separator: "|"))")
    }

    /// 记录任意一行（调试用；不依赖 stderr 重定向）
    static func note(_ line: String) {
        guard let path else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
