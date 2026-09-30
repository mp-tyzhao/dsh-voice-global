import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// 学习闭环自测
// ─────────────────────────────────────────────────────────────────────────────
//
// 这是产品头号功能，但它在真实使用里最难验证：需要一个别的 App、一个真输入框、
// 一次真粘贴、一次真修改。等用户去碰运气不是办法。
//
// 这里造一个受控的输入框，把**真实的**观测代码跑一遍：
//   建窗口 → 放文本框 → 聚焦 → 启动 EditWatcher → 程序化改文本 → 看是否学到
//
// 全程用真实的辅助功能读取、真实的轮询、真实的差异计算、真实的 learning.mjs。
// 配合临时 HOME 跑，不会碰用户自己的词表：
//
//   HOME=/tmp/vg-selftest "DSH Voice.app/Contents/MacOS/DSHVoice" --learn-selftest

final class LearnSelfTestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var sidecar: Sidecar!
    private var watcher: EditWatcher!
    private var stages: [(String, Bool)] = []

    /// 受控测试用的原始文本与用户改正后的文本。
    /// 用真实案例：说"用户侧自进化"被识别成"用户测自净化"。
    private let rawText = "你看用户测自净化这两个词都识别错了"
    private let correctedText = "你看用户侧自进化这两个词都识别错了"

    func applicationDidFinishLaunching(_ note: Notification) {
        var config = ConfigStore.load()
        config.learnFromEdits = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 140),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "学习闭环自测"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        textView = NSTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        scroll.documentView = textView
        window.contentView!.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        // 模拟"我们刚把转写结果粘进来"
        textView.string = rawText
        sidecar = Sidecar()
        watcher = EditWatcher(config: config, sidecar: sidecar)
        watcher.verbose = true   // 自测时把每次轮询的判断都记下来

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            // 观测代码要读的是"系统级焦点元素"，先确认真的读得到自己的文本框
            let focused = EditWatcher.focusedElement()
            let value = focused.flatMap { EditWatcher.value(of: $0) }
            record("辅助功能能读到受控输入框", value == rawText,
                   "读到的是：\(value?.prefix(30) ?? "nil")")

            record("输入框里是原始识别结果", textView.string == rawText)

            watcher.onLearned = { [weak self] added, pending in
                guard let self else { return }
                let all = added + pending
                self.record("检测到修改并从中学到词", all.contains("用户侧自进化"),
                            "生效：\(added.joined(separator: "、"))；待确认：\(pending.joined(separator: "、"))")
                // 单字替换推出来的词置信度 0.60，第一次只进待定区，这是设计如此。
                // 所以这里两种情况都算通过，只要**有反应**。
                self.record("低置信度候选进了待定区（不是静默丢弃）", !pending.isEmpty || !added.isEmpty,
                            "既没生效也没记录")
                self.finish()
            }
            watcher.start(pasted: rawText, raw: rawText)
            record("观测已启动", true)

            // 1.5 秒后模拟用户手工改正（超过一个轮询周期 1.2s）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard let editor = textView else { return }
                editor.string = correctedText
                record("已模拟用户改正", true)
            }

            // 兜底：8 秒还没学到就算失败
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [self] in
                record("检测到修改并从中学到词", false, "8 秒内没有触发学习回调")
                finish()
            }
        }
    }

    private func record(_ label: String, _ ok: Bool, _ detail: String = "") {
        stages.append((label, ok))
        print("\(ok ? "PASS" : "FAIL")  \(label)")
        if !ok, !detail.isEmpty { print("      \(detail)") }
        fflush(stdout)
    }

    private func finish() {
        // 词表里应该真的多出这个词
        let terms = describeTermsFromDisk()
        let pendingTerms = readPendingFromDisk()
        let recorded = terms.contains("用户侧自进化") || pendingTerms.contains("用户侧自进化")
        record("这个词被记下来了（词表或待定区）", recorded,
               "词表：\(terms.joined(separator: "、"))；待定：\(pendingTerms.joined(separator: "、"))")

        let failed = stages.filter { !$0.1 }.count
        print()
        if failed == 0 {
            print("ALL PASS（学习闭环端到端可用）")
        } else {
            print("\(failed) 项失败")
        }
        fflush(stdout)
        exit(failed == 0 ? 0 : 1)
    }

    /// 读待定区，验证低置信度候选确实被记下来了
    private func readPendingFromDisk() -> [String] {
        let path = Paths.home.appendingPathComponent("learning-pending.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Array(object.keys)
    }

    /// 直接读词表文件，不经过 sidecar —— 验证的是"落盘了没有"
    private func describeTermsFromDisk() -> [String] {
        let path = Paths.dictionary
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["terms"] as? [String] else { return [] }
        return list
    }
}
