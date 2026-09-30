import Foundation

/// 录音与转写元数据留存（特别版特性）
/// ==================================
///
/// 开启后（`config.keepRecordings`），每段录音连同转写元数据归档到：
///
/// ```
/// ~/.voice-global/recordings/
///   audio/2026-09-30T23-40-12-345Z.wav
///   index.jsonl          一行一条，可直接 jq / grep
/// ```
///
/// **音频只在本机，不会上传到任何地方。** 归档发生在转写完成之后，
/// 从临时目录搬过来；关掉这个开关就恢复"用完即删"。
///
/// 存在的意义：改了 VAD 阈值、换了模型、调了 prompt 之后，能拿同一批
/// 真实录音做前后对比，量出"到底有没有变准"，而不是靠感觉。
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
    static func archive(
        wav: URL,
        seconds: Double,
        raw: String,
        text: String,
        hits: [String],
        timings: [String: Int],
        config: VoiceConfig
    ) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        } catch {
            Log.shared.error("录音目录创建失败：\(error)")
            try? fileManager.removeItem(at: wav)
            return
        }

        let name = "\(stamp(for: Date())).wav"
        let destination = audioDirectory.appendingPathComponent(name)
        do {
            try fileManager.moveItem(at: wav, to: destination)
        } catch {
            Log.shared.error("录音归档失败：\(error)")
            try? fileManager.removeItem(at: wav)
            return
        }

        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "audio": "audio/\(name)",
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
        // 转写为空也是有用的信号（静音、气声、VAD 判错），照样记下来
        if raw.isEmpty { entry["empty"] = true }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            Log.shared.error("录音元数据序列化失败")
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
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let relative = object["audio"] as? String else {
                continue   // 坏行直接丢弃
            }
            let file = root.appendingPathComponent(relative)
            let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            let timestamp = (object["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

            var drop = false
            if let cutoff, let timestamp, timestamp < cutoff { drop = true }
            if let maxCount, kept.count >= maxCount { drop = true }
            if let maxBytes, totalBytes + size > maxBytes { drop = true }

            if drop {
                try? fileManager.removeItem(at: file)
                removed += 1
            } else {
                kept.append(line)
                totalBytes += size
            }
        }

        guard removed > 0 else { return }
        let rebuilt = kept.reversed().joined(separator: "\n") + "\n"
        try? Data(rebuilt.utf8).write(to: indexFile)
        Log.shared.info("录音留存清理：删除 \(removed) 条，保留 \(kept.count) 条 / \(totalBytes / 1024 / 1024)MB")
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

    /// 清空全部录音与元数据。
    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
        Log.shared.info("录音留存已清空")
    }
}
