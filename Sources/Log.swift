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
    }

    func info(_ message: String) { write("INFO ", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async { [path = Paths.log.path] in
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
