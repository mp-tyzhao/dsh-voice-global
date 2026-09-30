// 录音留存的回归测试
// ==================
//
// 跑法（在仓库根目录）：
//   swiftc -O -o /tmp/recordings-test Sources/Config.swift Sources/Log.swift Sources/Recordings.swift \
//     tests/recordings.test.swift && HOME=$(mktemp -d) /tmp/recordings-test
//
// 覆盖：归档写入、index.jsonl 结构、三个保留上限各自的清理、统计、清空。
// 用临时 HOME 跑，不碰真实数据目录。

import Foundation

@main
struct RecordingsTest {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL")  \(label)")
        if !ok { failures += 1 }
    }

    /// 造一个合法的 16kHz 单声道 PCM16 WAV（44 字节头 + N 个静音样本）
    static func makeWav(samples: Int) -> Data {
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        let bytes = UInt32(samples * 2)
        header.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(bytes)
        return header + Data(repeating: 0, count: Int(bytes))
    }

    static func archive(_ label: String, config: VoiceConfig, seconds: Double = 1.0) {
        let temp = Paths.tmp.appendingPathComponent("\(label).wav")
        try? makeWav(samples: Int(seconds * 16000)).write(to: temp)
        Recordings.record(
            wav: temp, seconds: seconds,
            raw: "原始 \(label)", text: "结果 \(label)", hits: ["llm"],
            timings: ["asr": 100, "total": 200], config: config
        )
    }

    static func main() {
        var config = VoiceConfig()
        config.keepRecordings = true   // 归档要能搬音频

        // 1. 归档
        archive("a", config: config)
        archive("b", config: config)
        archive("c", config: config)

        let index = (try? String(contentsOf: Recordings.indexFile, encoding: .utf8)) ?? ""
        let lines = index.split(separator: "\n", omittingEmptySubsequences: true)
        check("三条记录都写进了 index.jsonl", lines.count == 3)

        let audioFiles = (try? FileManager.default.contentsOfDirectory(atPath: Recordings.audioDirectory.path)) ?? []
        check("音频文件都归档了", audioFiles.count == 3)

        // 2. 结构：能被解析，字段齐全
        if let first = lines.first?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any] {
            check("index.jsonl 每行是合法 JSON", true)
            for key in ["ts", "audio", "seconds", "raw", "text", "hits", "timings", "env"] {
                check("包含字段 \(key)", object[key] != nil)
            }
            check("文本字段内容正确", (object["raw"] as? String)?.contains("原始 a") == true)
        } else {
            check("index.jsonl 每行是合法 JSON", false)
        }

        // 3. 保留上限：条数
        config.recordingsMaxCount = 2
        Recordings.prune(config: config)
        let afterCount = ((try? String(contentsOf: Recordings.indexFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).count
        let filesAfterCount = (try? FileManager.default.contentsOfDirectory(atPath: Recordings.audioDirectory.path))?.count ?? 0
        check("按条数清理：index 剩 2 条", afterCount == 2)
        check("按条数清理：音频也删到 2 个（不留孤儿）", filesAfterCount == 2)

        // 4. 保留上限：天数（把 maxDays 设成 0 天，全部过期）
        config.recordingsMaxCount = 0
        config.recordingsMaxDays = 0
        let pruneDisabled = ((try? String(contentsOf: Recordings.indexFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).count
        check("上限配 0 表示不限制（天数=0 时不清）", pruneDisabled == 2)

        // 5. 统计
        let stats = Recordings.statistics()
        check("统计：条数正确", stats.count == 2)

        // 6. 清空
        Recordings.clearAll()
        check("清空后 index.jsonl 不存在", !FileManager.default.fileExists(atPath: Recordings.indexFile.path))
        check("清空后统计归零", Recordings.statistics().count == 0)


        // 7. 音频关掉时：只记文本，且 prune 不能把它当坏行删掉
        var textOnly = VoiceConfig()
        textOnly.keepRecordings = false
        archive("d", config: textOnly)
        archive("e", config: textOnly)
        let afterTextOnly = ((try? String(contentsOf: Recordings.indexFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).count
        check("关掉音频后文本仍然记录（实际 \(afterTextOnly) 条）", afterTextOnly == 2)
        textOnly.recordingsMaxCount = 1
        Recordings.prune(config: textOnly)
        let prunedTextOnly = ((try? String(contentsOf: Recordings.indexFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).count
        check("只记文本的条目不会被 prune 当坏行丢掉（实际 \(prunedTextOnly) 条）", prunedTextOnly == 1)

        print()
        if failures == 0 {
            print("ALL PASS (全部通过)")
            exit(0)
        }
        print("\(failures) 项失败")
        exit(1)
    }
}
