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
