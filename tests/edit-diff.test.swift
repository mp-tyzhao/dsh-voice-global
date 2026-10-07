// 输入框差异计算的回归测试
// ========================
//
// 跑法（在仓库根目录）：
//   swiftc -O -o /tmp/edit-diff-test Sources/EditDiff.swift tests/edit-diff.test.swift \
//     && /tmp/edit-diff-test
//
// 这段逻辑决定"我们以为用户改了什么"。判错了会学到错误的词 ——
// 比识别错更糟，因为错误会被写进词表并影响之后的每一句话。

import Foundation

@main
struct EditDiffTest {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(label)")
        if !ok, !detail.isEmpty { print("      \(detail)") }
        if !ok { failures += 1 }
    }

    static func main() {
        // ---- commonEdges ----
        print("— 前后缀切分 —")
        do {
            let (p, s) = EditDiff.commonEdges("abcXYZdef", "abcABCdef")
            check("中间整段替换", p == 3 && s == 3, "prefix=\(p) suffix=\(s)")
        }
        do {
            let (p, s) = EditDiff.commonEdges("今天天气不错", "今天天气很好")
            check("中文中间改动", p == 4 && s == 0, "prefix=\(p) suffix=\(s)")
        }
        do {
            let (p, s) = EditDiff.commonEdges("我们想一想像tys那样", "我们想一想像Typeless那样")
            check("插入式改正（Typeless）", p == 6 && s == 3, "prefix=\(p) suffix=\(s)")
        }
        do {
            let (p, s) = EditDiff.commonEdges("原文", "原文")
            check("完全相同 → 前缀吃满，后缀为 0", p == 2 && s == 0, "prefix=\(p) suffix=\(s)")
        }
        do {
            let (p, s) = EditDiff.commonEdges("", "abc")
            check("空串不崩", p == 0 && s == 0, "prefix=\(p) suffix=\(s)")
        }
        do {
            // 关键：前后缀不能重叠。`aaa` → `aa` 若允许重叠会算出 prefix=2,suffix=1
            let (p, s) = EditDiff.commonEdges("aaa", "aa")
            check("前后缀不重叠（aaa→aa）", p + s <= min(3, 2), "prefix=\(p) suffix=\(s)")
        }

        // ---- window ----
        print("\n— 取上下文窗口 —")
        do {
            let text = String(repeating: "前", count: 300) + "改动" + String(repeating: "后", count: 300)
            let w = EditDiff.window(text, prefix: 300, suffix: 300, radius: 160)
            check("窗口被裁到改动点附近", w.count < text.count, "\(w.count) vs \(text.count)")
            check("改动内容在窗口里", w.contains("改动"))
        }
        do {
            let w = EditDiff.window("短文本", prefix: 1, suffix: 1, radius: 160)
            check("文本比窗口短时原样返回", w == "短文本", w)
        }

        // ---- correctedPasted ----
        print("\n— 还原粘贴段被改成了什么 —")
        do {
            // 输入框里已有前缀，我们把 "TYS" 粘在中间
            let old = "前缀 TYS 后缀"
            let new = "前缀 Typeless 后缀"
            let corrected = EditDiff.correctedPasted(old: old, new: new, pastedStart: 3, pastedEnd: 6)
            check("插入式改正还原正确", corrected == "Typeless", corrected ?? "nil")
        }
        do {
            let old = "abc原始def"
            let new = "abc改正def"
            let corrected = EditDiff.correctedPasted(old: old, new: new, pastedStart: 3, pastedEnd: 5)
            check("替换式改正还原正确", corrected == "改正", corrected ?? "nil")
        }
        do {
            // 用户把粘贴的内容删光了
            let old = "abcXYZdef"
            let new = "abcdef"
            let corrected = EditDiff.correctedPasted(old: old, new: new, pastedStart: 3, pastedEnd: 6)
            check("整段删除 → 空串（不是 nil）", corrected == "", corrected ?? "nil")
        }
        do {
            let old = "abcXYZdef"
            let new = "abcXYZdef"
            let corrected = EditDiff.correctedPasted(old: old, new: new, pastedStart: 3, pastedEnd: 6)
            check("没改动时原样返回", corrected == "XYZ", corrected ?? "nil")
        }
        do {
            // 越界保护
            let bad = EditDiff.correctedPasted(old: "abc", new: "ab", pastedStart: 5, pastedEnd: 9)
            check("越界返回 nil 而不是崩溃", bad == nil, bad ?? "nil")
        }

        // ---- isSameDocument ----
        print("\n— 判断是不是同一段文本 —")
        do {
            // 原地改几个字：这是我们想抓的情况
            let before = "你看用户测自净化这两个词都识别错了，这也不是什么特别生僻的字，怎么会这样呢"
            let after  = "你看用户侧自进化这两个词都识别错了，这也不是什么特别生僻的字，怎么会这样呢"
            check("原地改字 → 同一段", EditDiff.isSameDocument(before, after))
        }
        do {
            // 换到了完全不同的文档：不该当成纠正
            let before = "你看用户测自净化这两个词都识别错了"
            let after  = "明天的会议改到下午三点，记得带上材料"
            check("换成别的文档 → 不是同一段", !EditDiff.isSameDocument(before, after))
        }
        do {
            let before = "很短的句子"
            check("同一句没变 → 同一段", EditDiff.isSameDocument(before, before))
            check("空串 → 不是同一段", !EditDiff.isSameDocument("", "任何内容"))
        }
        do {
            // 长文档里删掉一大段，公共前后缀不多，但仍属同一文档
            let head = String(repeating: "前", count: 200)
            let tail = String(repeating: "后", count: 200)
            check("长文档大段删除 → 仍是同一段",
                  EditDiff.isSameDocument(head + "中间一大段内容" + tail, head + tail))
        }

        // ---- classify：区分"修正"和"改主意删减" ----
        print("\n— 这次编辑是修正还是删减 —")
        do {
            check("删掉一整句 → 删减",
                  EditDiff.classify(before: "我觉得这个方案可行，而且风险也不大",
                                    after: "我觉得这个方案可行") == .trim)
        }
        do {
            check("改掉一个字 → 修正",
                  EditDiff.classify(before: "我们用聚水谭管订单", after: "我们用聚水潭管订单") == .fix)
        }
        do {
            check("插入内容 → 修正",
                  EditDiff.classify(before: "我们用管订单", after: "我们用聚水潭管订单") == .fix)
        }
        do {
            check("删一句 + 改一个字 → 修正（改的那个仍要学）",
                  EditDiff.classify(before: "我们用聚水谭管订单，另外还有别的",
                                    after: "我们用聚水潭管订单") == .fix)
        }
        do {
            check("完全没改 → 修正（不是删减）",
                  EditDiff.classify(before: "原文", after: "原文") == .fix)
        }
        do {
            // 关键反例：删一个字符也可能是修 ASR 多识别的字母，不是改主意
            check("RSSI → RSI 是修正（删 1 字，不是改主意）",
                  EditDiff.classify(before: "我们要实现语音输入的 RSSI", after: "我们要实现语音输入的 RSI") == .fix)
        }
        do {
            // 删重复的中文字也判成删减。这是有意的取舍：
            // 用户的 5 条真实中文字删除全是措辞改动，按"删中文=改措辞"处理
            // 会把偶尔的"修掉重复字"也归进去 —— 代价是这条不计入修正率。
            // 反过来（把措辞改动当成修正）代价更大：CER 和修正率都虚高。
            // 而且纯删除本来也抽不出术语，学习信号没有损失。
            check("删掉重复的中文字 → 删减（有意取舍）",
                  EditDiff.classify(before: "你看看这个的的写法", after: "你看看这个的写法") == .trim)
        }
        do {
            check("删掉小半句 → 删减",
                  EditDiff.classify(before: "我觉得这个方案可行，而且风险也不大，可以先试试看",
                                    after: "我觉得这个方案可行") == .trim)
        }
        // 下面 5 条全部来自用户 2026-10-07 的真实记录。
        // 它们都是"删掉一两个字的措辞改动"，不是识别错误 —— 第一版按
        // "删≤8字算修正"的判据把它们全判错了。
        for (label, before, after) in [
            ("删掉一个中文字（奇绩创坛→奇绩创）", "奇绩创坛", "奇绩创"),
            ("删掉句首的「是」（不是→不）", "不是我从楼顶拍的", "不我从楼顶拍的"),
            ("删掉一个名词（地图不需要调整）", "地图不需要调整", "不需要调整"),
            ("删掉一个多余的「至」", "左右是至17.5米", "左右是17.5米"),
            ("删掉句首的「我」", "我现在的绿点连成的红线", "现在的绿点连成的红线"),
        ] {
            check("\(label) → 删减", EditDiff.classify(before: before, after: after) == .trim)
        }
        do {
            check("删中文里夹的拉丁字符不影响判定",
                  EditDiff.classify(before: "部署到staging环境", after: "部署到stging环境") == .fix)
        }

        // ---- 端到端：真实场景串起来 ----
        print("\n— 真实场景：用户把 TYS 改成 Typeless —")
        do {
            let old = "我们想一想，怎么样能像TYS那样，把一些专有术语识别得越来越好"
            let new = "我们想一想，怎么样能像Typeless那样，把一些专有术语识别得越来越好"
            let pastedStart = 0
            let pastedEnd = old.count
            let (prefix, suffix) = EditDiff.commonEdges(old, new)
            let oldWindow = EditDiff.window(old, prefix: prefix, suffix: suffix)
            let newWindow = EditDiff.window(new, prefix: prefix, suffix: suffix)
            let corrected = EditDiff.correctedPasted(old: old, new: new, pastedStart: pastedStart, pastedEnd: pastedEnd)
            check("改动被定位", oldWindow != newWindow)
            check("学习窗口包含错误写法 TYS", oldWindow.contains("TYS"), oldWindow)
            check("学习窗口包含正确写法 Typeless", newWindow.contains("Typeless"), newWindow)
            check("整段标注还原正确", corrected == new, corrected ?? "nil")
        }

        print()
        if failures == 0 {
            print("ALL PASS (全部通过)")
            exit(0)
        }
        print("\(failures) 项失败")
        exit(1)
    }
}
