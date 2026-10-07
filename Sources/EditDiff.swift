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
    /// 用真实数据校准过（2026-10-07，用户 7 条修订记录）：
    ///
    ///   RSSI → RSI                 识别修正（删的是拉丁词内部的字符）
    ///   奇绩创坛 → 奇绩创          ┐
    ///   不是我从楼顶 → 不我从楼顶    │
    ///   地图不需要调整 → 不需要调整  ├ 全是「删掉一两个字的措辞改动」
    ///   左右是至17.5米 → 左右是17.5米│  不是识别错误
    ///   我现在的绿点 → 现在的绿点    ┘
    ///
    /// 所以分界**不是删除的量**（第一版按"删≤8字算修正"判，把这 5 条全判错了），
    /// 而是**删的是不是中文**：
    ///   · 删拉丁字母（RSSI→RSI）→ 修 ASR 多识别的字符
    ///   · 删中文字 → 用户改措辞，跟识别对不对没关系
    ///
    /// 宁可把改措辞判成修正（顶多让指标保守），也不要反过来 ——
    /// 那会让 CER 和修正率都虚高，指标就不可信了。
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

        // 纯删除：找出被删掉的那些字符，看里面有没有中文
        var deleted: [Character] = []
        var j = 0
        for character in b {
            while a[j] != character { deleted.append(a[j]); j += 1 }
            j += 1
        }
        deleted.append(contentsOf: a[j...])

        let removedCJK = deleted.contains { character in
            character.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        return removedCJK ? .trim : .fix
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
