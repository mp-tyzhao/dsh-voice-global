import AppKit
import ApplicationServices

/// 观测用户在输入框里对转写结果的修改
/// ==================================
///
/// 这是"越用越聪明"的信号来源。用户手工把 `TYS` 改成 `Typeless`、把 `奇迹创谈`
/// 改成 `奇绩创坛` —— 每一个改动都是他真正想说的词，比任何训练数据都准。
///
/// ## 做法
///
/// 粘贴成功后读一次焦点输入框的内容（Before），之后轮询；内容一变就把
/// (Before 窗口, After 窗口) 交给学习模块（[Sidecar.learn]）。
///
/// 为什么读"整个输入框前后对比"而不是只记我们粘贴的那段：
/// 这样拿到的是**真实的前后差异**，用户删掉一半、改中间、补字都能如实捕获；
/// 只盯着自己粘的那段则要靠猜边界。
///
/// ## 边界（都是刻意的）
///
/// - **只在粘贴后的短窗口内观测**，不做常驻监视，到点自动停
/// - **焦点一换就停** —— 用户去改别的地方与我们无关
/// - 目标 App 不暴露文本（Electron、终端、部分网页输入框）时**静默放弃**，不影响使用
/// - **内容不离开本机**：只用来抽术语、写进本地词表
final class EditWatcher {
    /// 观测窗口。
    ///
    /// 25 秒太短了 —— 实测：用户 16:01:02 粘贴，25 秒窗口在 16:01:27 结束，
    /// 而他 16:01:30 就开始了下一次听写，改动正好落在窗口外。人读完再改需要时间。
    /// VoiceInk 用的是 60 秒，这里跟它对齐。
    private static let watchSeconds: TimeInterval = 60
    private static let pollInterval: TimeInterval = 1.2
    /// 输入框内容超过这个长度就不观测。
    /// 每 1.2 秒读一次全文、还要做一次前后缀比较，编辑器里开着几 MB 文档时
    /// 这个开销不划算；而且那么长的文本里用户改了几个字，本来也不是听写纠正。
    static let maxWatchedCharacters = 20_000

    private var timer: Timer?
    private var element: AXUIElement?
    private var before: String = ""
    private var pasted: String = ""
    private var raw: String = ""
    private var deadline = Date()

    private let config: VoiceConfig
    private let sidecar: Sidecar
    /// 学习有结果时回调：第一个参数是直接生效的词，第二个是先进待定区的词。
    /// 两者都要告诉用户 —— 不然改完了界面没反应，像是坏了。
    var onLearned: (([String], [String]) -> Void)?
    /// 自测时打开，把每次轮询的判断都写进日志
    var verbose = false
    /// 用户把整段转写改成了什么样 —— 写回语料当标注
    var onCorrection: ((String) -> Void)?

    init(config: VoiceConfig, sidecar: Sidecar) {
        self.config = config
        self.sidecar = sidecar
    }

    /// 粘贴成功后调用。
    func start(pasted: String, raw: String) {
        stop()
        guard config.learnFromEdits, Injector.isTrusted else { return }

        guard let focused = EditWatcher.focusedElement(),
              let text = EditWatcher.value(of: focused) else {
            // 目标 App 不暴露文本就读不到，正常情况，不当错误
            Log.shared.info("学习：当前输入框不提供文本，本次跳过")
            return
        }

        self.element = focused
        self.pasted = pasted
        self.raw = raw
        self.deadline = Date().addingTimeInterval(EditWatcher.watchSeconds)

        // 等粘贴真正落地再定基线。
        //
        // ⌘V 是**异步**的：Injector 把按键发出去之后就回调了，此刻目标 App
        // 往往还没处理完，读到的还是旧值。实测日志里 13 次观测有 11 次读到
        // 0 或 1 字 —— 拿这个当基线的话，后面每一轮都判不出"还是同一段文本"，
        // 观测等于白开，学习闭环一次都不会触发。这就是那个根因。
        settle(initial: text, attempt: 0)
    }

    /// 轮询等待粘贴落地（文本变得和刚读完时不一样），最多等约 1.8 秒。
    private func settle(initial: String, attempt: Int) {
        guard attempt < 12 else {
            Log.shared.info("学习：粘贴后输入框始终没有变化，本次不观测")
            stop()
            return
        }
        guard Date() < deadline else { stop(); return }
        guard let current = EditWatcher.focusedElement(),
              let text = EditWatcher.value(of: current) else {
            Log.shared.info("学习：当前输入框不提供文本，本次跳过")
            stop()
            return
        }

        // 落地判据用"变了"，不强求包含完整粘贴内容 —— 有些 App 会做自动格式化
        // （补全括号、改写引号），逐字比对会永远等不到。
        //
        // 另一条 `contains(pasted)` 是给自测留的：那边文本已经在框里了，
        // 不会有"变化"，只看第一条会一直等到超时。
        let landed = (!text.isEmpty && text != initial) || text.contains(pasted)
        guard landed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.settle(initial: initial, attempt: attempt + 1)
            }
            return
        }

        guard text.count <= EditWatcher.maxWatchedCharacters else {
            Log.shared.info("学习：输入框内容过长（\(text.count) 字），本次不观测")
            stop()
            return
        }

        self.element = current
        self.before = text
        Log.shared.info("学习：开始观测输入框（\(text.count) 字），\(Int(EditWatcher.watchSeconds)) 秒内的改动会被学习")

        let timer = Timer.scheduledTimer(withTimeInterval: EditWatcher.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        before = ""
    }

    // MARK: - 轮询

    private func poll() {
        let trace = { (message: String) in
            if self.verbose { Log.shared.info("自测轮询：\(message)") }
        }
        guard Date() < deadline else {
            trace("超时结束")
            stop()
            return
        }
        guard let current = EditWatcher.focusedElement() else {
            trace("拿不到焦点元素")
            stop()
            return
        }
        guard let now = EditWatcher.value(of: current) else {
            trace("焦点元素不提供文本")
            stop()
            return
        }
        guard now != before else {
            trace("内容未变（\(now.count) 字）")
            return
        }

        // 判断"还是不是同一段文本"，而不是"还是不是同一个 AX 元素"。
        //
        // 原先用 CFEqual 比元素身份，是个真 bug：很多 App（尤其网页输入框）
        // 每次交互都会重建 AX 元素 —— 用户一点进文本框准备改，身份就变了，
        // 观测当场停止，改动永远抓不到。实测就栽在这里。
        //
        // 内容判据更稳：原地修改会保留大部分文本，换到别的文档则不会。
        guard EditDiff.isSameDocument(before, now) else {
            trace("内容已不是同一段（\(before.count) → \(now.count) 字）")
            stop()
            return
        }
        trace("检测到改动（\(before.count) → \(now.count) 字）")

        // 必须先把两个字符串取出来再 stop()。
        //
        // stop() 会把 self.before 清空，而 Swift 的实参是在调用点求值的 ——
        // 写成 `stop(); handleChange(from: before, to: now)` 的话，
        // handleChange 拿到的原文是空串，`"".range(of: pasted)` 恒为 nil，
        // 于是每一次改正都在这里被静默丢掉。
        //
        // 这个 bug 从第一版就在：学习闭环从来没有真正抓到过任何一次修改。
        // 是 --learn-selftest 把它逼出来的 —— 光靠真实使用永远只会看到"没反应"。
        let previous = before
        let latest = now
        element = current
        stop()
        handleChange(from: previous, to: latest)
    }

    /// 输入框内容变了：确认改动落在我们粘贴的那段里，再交给学习。
    private func handleChange(from old: String, to new: String) {
        // 1. 我们粘的那段得还在（用户可能把它删了，那不算纠正）
        guard let pastedRange = old.range(of: pasted), !pasted.isEmpty else {
            if verbose { Log.shared.info("自测轮询：粘贴段已不在新内容里") }
            return
        }

        // 2. 找出改动的区间
        let (prefix, suffix) = EditDiff.commonEdges(old, new)
        guard prefix < old.count - suffix else { return }   // 纯删除到什么都不剩

        let changeStart = old.index(old.startIndex, offsetBy: prefix)
        let changeEnd = old.index(old.endIndex, offsetBy: -suffix)
        guard changeStart < changeEnd else { return }
        // 改动必须与粘贴段相交，否则是用户在编辑别的地方
        guard changeStart < pastedRange.upperBound, changeEnd > pastedRange.lowerBound else {
            if verbose { Log.shared.info("自测轮询：改动不在粘贴段内") }
            return
        }

        // 3. 取改动点前后一段窗口（带上文，学习模块靠对齐找边界）
        let oldWindow = EditDiff.window(old, prefix: prefix, suffix: suffix)
        let newWindow = EditDiff.window(new, prefix: prefix, suffix: suffix)

        guard oldWindow != newWindow else { return }

        // 4. 顺带算出「我们粘贴的那段」被改成什么样 —— 这是整段转写的正确答案，
        //    写回语料当标注，之后算准确率、做回归都靠它。
        let pastedStart = old.distance(from: old.startIndex, to: pastedRange.lowerBound)
        let pastedEnd = old.distance(from: old.startIndex, to: pastedRange.upperBound)
        if let corrected = EditDiff.correctedPasted(old: old, new: new, pastedStart: pastedStart, pastedEnd: pastedEnd) {
            onCorrection?(corrected)
        }

        Log.shared.info("学习：检测到用户改正（\(oldWindow.count) → \(newWindow.count) 字）")

        sidecar.learn(raw: oldWindow, corrected: newWindow, config: config) { [weak self] added, pending in
            guard !added.isEmpty || !pending.isEmpty else { return }
            if !added.isEmpty { Log.shared.info("学到新词：\(added.joined(separator: "、"))") }
            if !pending.isEmpty { Log.shared.info("记住待确认：\(pending.joined(separator: "、"))") }
            self?.onLearned?(added, pending)
        }
    }

    /// 粘贴段在改动后的样子。前缀长度不变，所以只需按总长度差平移尾部。
    static func correctedPasted(old: String, new: String, pastedRange: Range<String.Index>) -> String? {
        let start = old.distance(from: old.startIndex, to: pastedRange.lowerBound)
        let end = old.distance(from: old.startIndex, to: pastedRange.upperBound)
        let tail = old.count - end
        let newEnd = new.count - tail
        guard newEnd >= start, newEnd <= new.count else { return nil }
        let lower = new.index(new.startIndex, offsetBy: start)
        let upper = new.index(new.startIndex, offsetBy: newEnd)
        return String(new[lower..<upper])
    }

    // MARK: - 工具

    // MARK: - 辅助功能

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// 读输入框当前文本。读不到（App 不暴露）返回 nil。
    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
