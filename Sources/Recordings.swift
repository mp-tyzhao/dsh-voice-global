import Foundation

/// 语料留存：转写文本 + （可选）录音
/// ================================
///
/// ```
/// ~/.voice-global/recordings/
///   audio/2026-09-30T23-40-12-345Z.wav     ← 仅 keepRecordings 开启时
///   index.jsonl                             ← 一行一条，可直接 jq / grep
/// ```
///
/// **转写文本永远记录**（很小，而且学习闭环依赖它）；**音频是可选的**，
/// 因为音频敏感得多 —— `config.keepRecordings` 控制。
///
/// 每条记录里最重要的是三样：
///   `raw`       ASR 原始输出（错在哪）
///   `text`      实际粘贴出去的文本
///   `corrected` 用户后来手工改成什么样 ← 这是学习闭环的输入
///
/// 有了 (raw, corrected) 这一对，就能算出真实准确率、抽出该学的术语。
/// **全部留在本机，不会上传到任何地方。**
enum Recordings {
    static var root: URL { Paths.home.appendingPathComponent("recordings", isDirectory: true) }
    static var audioDirectory: URL { root.appendingPathComponent("audio", isDirectory: true) }
    static var indexFile: URL { root.appendingPathComponent("index.jsonl") }

    /// 时间戳既做文件名也做排序键：`2026-09-30T23-40-12-345Z`（文件名安全，无冒号）。
    private static func stamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return formatter.string(from: date)
    }

    /// 归档一段录音，并追加一条元数据。
    /// - Parameters:
    ///   - wav: 临时 WAV 路径；方法内部负责搬运（成功后原文件不再存在）
    ///   - raw: ASR 原始输出
    ///   - text: 实际粘贴出去的最终文本
    ///   - hits: 命中的清理规则
    ///   - timings: 各阶段耗时（毫秒）
    ///   - config: 当前配置，用于记录当时的环境
    static func record(
        wav: URL,
        seconds: Double,
        raw: String,
        text: String,
        hits: [String],
        timings: [String: Int],
        config: VoiceConfig
    ) {
        let fileManager = FileManager.default

        // 文本永远记录：先保证目录在。关掉音频时不会走到下面的 audioDirectory 分支，
        // 如果这里不建目录，写 index.jsonl 会静默失败（被测试抓到过）。
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 音频是可选的：关掉就沿用"用完即删"。文本永远记录。
        var audioField: String?
        if config.keepRecordings {
            do {
                try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                let name = "\(stamp(for: Date())).wav"
                try fileManager.moveItem(at: wav, to: audioDirectory.appendingPathComponent(name))
                audioField = "audio/\(name)"
            } catch {
                Log.shared.error("录音归档失败，本条只记文本：\(error)")
                try? fileManager.removeItem(at: wav)
            }
        } else {
            try? fileManager.removeItem(at: wav)
        }

        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "seconds": (seconds * 1000).rounded() / 1000,
            "raw": raw,
            "text": text,
            "hits": hits,
            "timings": timings,
            "env": [
                "language": config.language,
                "cleanup": config.cleanup,
                "llmModel": config.llm.enabled ? config.llm.model : "",
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            ],
        ]
        if let audioField { entry["audio"] = audioField }
        // 转写为空也是有用的信号（静音、气声、VAD 判错），照样记下来
        if raw.isEmpty { entry["empty"] = true }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            Log.shared.error("语料元数据序列化失败")
            return
        }
        line += "\n"

        if let handle = try? FileHandle(forWritingTo: indexFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: indexFile)
        }

        prune(config: config)
    }

    /// 按条数 / 总大小 / 天数三个上限清理最旧的记录。任何一项配 0 表示该项不限制。
    static func prune(config: VoiceConfig) {
        let fileManager = FileManager.default
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return }

        let cutoff = config.recordingsMaxDays > 0
            ? Date().addingTimeInterval(-Double(config.recordingsMaxDays) * 86400)
            : nil
        let maxBytes = config.recordingsMaxMB > 0 ? config.recordingsMaxMB * 1024 * 1024 : nil
        let maxCount = config.recordingsMaxCount > 0 ? config.recordingsMaxCount : nil

        // index.jsonl 是按时间追加的，从后往前保留，超出上限的丢掉
        var kept: [String] = []
        var totalBytes = 0
        var removed = 0

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue   // 坏行直接丢弃
            }
            // 音频是可选的：只记文本的条目（keepRecordings 关掉时）也要留住，别当坏行删了
            var size = 0
            var audioFile: URL?
            if let relative = object["audio"] as? String {
                let file = root.appendingPathComponent(relative)
                audioFile = file
                size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            }
            let timestamp = (object["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

            var drop = false
            if let cutoff, let timestamp, timestamp < cutoff { drop = true }
            if let maxCount, kept.count >= maxCount { drop = true }
            if let maxBytes, totalBytes + size > maxBytes { drop = true }

            if drop {
                if let audioFile { try? fileManager.removeItem(at: audioFile) }
                removed += 1
            } else {
                kept.append(line)
                totalBytes += size
            }
        }

        guard removed > 0 else { return }
        let rebuilt = kept.reversed().joined(separator: "\n") + "\n"
        try? Data(rebuilt.utf8).write(to: indexFile)
        Log.shared.info("语料清理：删除 \(removed) 条，保留 \(kept.count) 条 / \(totalBytes / 1024 / 1024)MB")
    }

    /// 读全部条目（原样返回字典，调用方自己取字段）。
    static func allEntries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// 最近一条有转写内容的记录 —— 显式纠正用它当默认值。
    static func lastTranscript() -> (ts: String, raw: String, text: String)? {
        for entry in allEntries().reversed() {
            guard let ts = entry["ts"] as? String,
                  let raw = entry["raw"] as? String,
                  let text = entry["text"] as? String,
                  !text.isEmpty else { continue }
            return (ts, raw, text)
        }
        return nil
    }

    /// 把用户手工改成的版本写回对应记录，作为学习与评测的标注。
    /// 逐行重写文件：条目不多（上限几百条），简单可靠比省 IO 重要。
    @discardableResult
    static func applyCorrection(ts: String, corrected: String) -> Bool {
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var updated = false

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["ts"] as? String == ts else { continue }
            object["corrected"] = corrected
            object["correctedAt"] = ISO8601DateFormatter().string(from: Date())
            guard let newData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let newLine = String(data: newData, encoding: .utf8) else { break }
            lines[index] = newLine
            updated = true
            break
        }

        guard updated else { return false }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: indexFile)
        return true
    }

    /// 已留存的条数与占用，用于菜单展示。
    static func statistics() -> (count: Int, megabytes: Int) {
        let fileManager = FileManager.default
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return (0, 0) }
        let count = text.split(separator: "\n", omittingEmptySubsequences: true).count

        // 目录本身的 size 在 APFS 上没有意义，直接累加音频文件
        var bytes = 0
        if let files = try? fileManager.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for file in files {
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return (count, bytes / 1024 / 1024)
    }

    /// 清空全部语料与录音。
    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
        Log.shared.info("语料与录音已清空")
    }
}
