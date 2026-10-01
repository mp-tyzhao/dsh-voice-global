import Foundation

/// 输入框前后差异的计算
/// ====================
///
/// 从 [EditWatcher] 里抽出来的纯函数，不依赖 AppKit / 辅助功能，
/// 因此可以独立单测 —— 这段逻辑决定了"我们以为用户改了什么"，
/// 错了会学到错误的词，比识别错更糟。
enum EditDiff {
    /// 改动点交给学习模块时，前后各带多少字当上下文。
    static let contextRadius = 160

    /// 两端相同的字符数：(前缀长度, 后缀长度)。前后缀保证不重叠。
    ///
    /// 例：`abcXYZdef` → `abcde f` 之类的改动，前缀 `abc`、后缀 `def`，
    /// 中间那段就是改动区间。
    static func commonEdges(_ a: String, _ b: String) -> (prefix: Int, suffix: Int) {
        let x = Array(a)
        let y = Array(b)
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix,
              x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        return (prefix, suffix)
    }

    /// 改动点附近的一段窗口（原文侧）。带上文是为了让学习模块能靠对齐找到术语边界。
    static func window(_ text: String, prefix: Int, suffix: Int, radius: Int = contextRadius) -> String {
        let characters = Array(text)
        let lower = max(0, prefix - radius)
        let upper = min(characters.count, characters.count - suffix + radius)
        guard lower < upper else { return text }
        return String(characters[lower..<upper])
    }

    /// 两段文本"还是不是同一段" —— 原地修改 vs 换到了别的文档。
    ///
    /// 用来替代"比较 AX 元素身份"：很多 App 每次交互都会重建 AX 元素，
    /// 身份判据会让观测在用户刚要点进去改的瞬间就停止。
    /// 内容判据更稳：原地修改保留大部分文本，换文档则不会。
    static func isSameDocument(_ before: String, _ after: String) -> Bool {
        guard !before.isEmpty else { return false }
        let (prefix, suffix) = commonEdges(before, after)
        // 门槛取 min(一半长度, 40)：短文本按比例，长文本给足余量
        // （长文档里改一大段，公共前后缀可能远不到一半）
        return prefix + suffix >= min(before.count / 2, 40)
    }

    /// 这次编辑是「修正识别错误」还是「改主意删减」。
    ///
    /// 两者的性质完全不同：
    ///   · 修正：用户把听错的字改成对的 → 是学习信号，也是评测的标准答案
    ///   · 删减：用户觉得这句话不该说，删掉了 → **不是**识别错误，
    ///           学不到东西，也不能当成"他实际说了什么"去算准确率
    ///
    /// 判据：改完之后的内容是不是原文的**子序列**（只删不换不增）。
    /// 是 → 删减。
    enum EditKind: String {
        case fix      // 有替换或插入：在纠正识别的错
        case trim     // 只删不换：改主意了
    }

    /// 判断这次编辑属于哪一类。
    ///
    /// 光看"是不是纯删减"不够 —— `RSSI → RSI` 和 `奇绩创坛 → 奇绩创`
    /// 都是"删掉一个字符"，但前者是修 ASR 多识别了一个字母，
    /// 后者更可能是用户改主意不想要那个字。
    ///
    /// 真正的区分信号是**删掉的量**：
    ///   · 删一两个字 → 修错字（识别问题）
    ///   · 删掉小半句 / 一整句 → 改主意（内容问题）
    ///
    /// 阈值取"超过 8 个字 或 超过原文 30%"。宁可把删减判成修正（顶多让
    /// CER 保守一点），也不要反过来 —— 那会丢掉真实的修正信号。
    static func classify(before: String, after: String) -> EditKind {
        let a = Array(before)
        let b = Array(after)
        guard b.count < a.count else { return .fix }    // 没变短：必然有替换或插入

        // 双指针判断 b 是否为 a 的子序列（只删不换）
        var i = 0
        for character in b {
            while i < a.count, a[i] != character { i += 1 }
            if i == a.count { return .fix }             // 对不上 → 有替换，是修正
            i += 1
        }

        let deleted = a.count - b.count
        let ratio = Double(deleted) / Double(max(a.count, 1))
        return (deleted > 8 || ratio > 0.3) ? .trim : .fix
    }

    /// 我们粘贴的那一段，在用户改完之后变成了什么样。
    ///
    /// 前缀长度不变，所以只需按总长度差把尾部平移过来。
    /// 这是整段转写的"正确答案"，写回语料当标注。
    static func correctedPasted(old: String, new: String, pastedStart: Int, pastedEnd: Int) -> String? {
        let tail = old.count - pastedEnd
        let newEnd = new.count - tail
        guard pastedStart >= 0, newEnd >= pastedStart, newEnd <= new.count else { return nil }
        let characters = Array(new)
        return String(characters[pastedStart..<newEnd])
    }
}
