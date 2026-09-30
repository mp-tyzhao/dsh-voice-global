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
