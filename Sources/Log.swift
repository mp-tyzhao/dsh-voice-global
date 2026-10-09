import Foundation

/// 极简文件日志：GUI 应用没有终端，所有诊断都落盘到 ~/.dsh-voice-global/log.txt。
final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "ai.dsh.voice-global.log")
    private let formatter = ISO8601DateFormatter()

    private init() {
        // 日志文件超过 1 MiB 时轮转，避免无限增长
        let path = Paths.log.path
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 1_048_576 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        // 退出前把队列里没写完的日志冲掉。
        //
        // 为什么需要：write() 现在是**全异步**的（见下），而 CLI 模式（--check、
        // --learn-selftest 等）记完日志就 exit() —— 不冲一下，最后几行会丢，
        // 而自测正是靠这些行判断结果的。
        // 注册在 atexit 里，一处覆盖全部 20 个 exit() 调用点。
        atexit { Log.shared.flush() }
    }

    /// 等待队列里所有日志写完。退出前用。
    func flush() {
        queue.sync {}
    }

    func info(_ message: String) { write("INFO ", message) }
    func error(_ message: String) { write("ERROR", message) }

    /// 写一条日志。**调用方永不阻塞** —— 全部推给后台串行队列。
    ///
    /// 原先 stderr 那一行是在**调用线程上同步写**的。这在事件 tap 回调里是
    /// 真实的阻塞风险：GUI 应用的 stderr 走系统日志，写不动就会卡住回调，
    /// 而 tap 回调超时会被系统直接禁用 —— 于是 Fn 就不响应了。
    /// 日志是诊断工具，不该成为不稳定源。
    ///
    /// 顺序性：stderr 与落盘都排在同一个串行队列上，先后关系不变。
    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        let data = Data(line.utf8)
        queue.async { [path = Paths.log.path] in
            FileHandle.standardError.write(data)
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
