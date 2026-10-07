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
    /// 观测代次。每次 start/stop 都自增，用来作废还没跑完的 settle 重试。
    ///
    /// 为什么需要：settle 靠 asyncAfter 重试，最多等 1.8 秒。如果两次听写
    /// 间隔很短，上一次的 settle 回调还会继续跑 —— 它会拿**旧的 pasted**
    /// 去配**新的输入框内容**，算出一个错误的差异交给学习，等于学到垃圾。
    private var generation = 0
    /// 已经提示过"这个 App 学不了"的名单。
    /// 每个 App 只提示一次 —— 用户需要知道，但不能每次听写都唠叨。
    private static var warnedApps = Set<String>()
    /// 当前 App 不支持自动学习时回调（每个 App 只回调一次），
    /// 用来在界面上告诉用户"这里学不了，请用纠正最近一次"。
    var onUnsupported: ((String) -> Void)?
    /// 用户把整段转写改成了什么样（含这次是「修正」还是「改主意删减」）
    /// —— 写回语料当标注。两者必须分开：删减不是识别错误，
    /// 当成"他实际说了什么"去算准确率会让 CER 虚高。
    var onCorrection: ((String, EditDiff.EditKind) -> Void)?

    init(config: VoiceConfig, sidecar: Sidecar) {
        self.config = config
        self.sidecar = sidecar
    }

    /// 粘贴成功后调用。
    func start(pasted: String, raw: String) {
        stop()
        guard config.learnFromEdits, Injector.isTrusted else { return }

        self.pasted = pasted
        self.raw = raw
        self.deadline = Date().addingTimeInterval(EditWatcher.watchSeconds)
        generation += 1
        settle(initial: nil, attempt: 0, generation: generation)
    }

    /// 等两件事：粘贴落地，以及**输入框变得读得到**。
    ///
    /// 为什么读不到也要重试：Chromium 系 App（Edge、飞书、各种 Electron）
    /// 只在被辅助功能查询时才去构建自己的 AX 树，第一次读常常是空的。
    /// 实测（2026-10-07）用户在 Edge / 飞书 里连续 10 次听写都读到
    /// "不提供文本"，两小时里学习完全没工作，而他只看到"改了词没反应"。
    /// 一次读不到就放弃太早了 —— 给它一点时间。
    ///
    /// 同时还要等粘贴落地：⌘V 是异步的，此刻读到的往往是粘贴前的旧值
    /// （空的输入框就是 0 字）。拿那个当基线，后面每一轮都判不出
    /// "还是同一段文本"，观测等于白开。
    private func settle(initial: String?, attempt: Int, generation: Int) {
        guard generation == self.generation else { return }   // 已被新的观测取代
        guard Date() < deadline else {
            if initial == nil { reportUnsupported() }
            stop()
            return
        }
        guard attempt < 24 else {
            if initial == nil {
                reportUnsupported()
            } else {
                Log.shared.info("学习：粘贴后输入框始终没有变化，本次不观测")
            }
            stop()
            return
        }
        guard let current = EditWatcher.focusedElement(),
              let text = EditWatcher.value(of: current) else {
            // 读不到就再等等 —— 可能是 Chromium 还没把 AX 树建起来
            scheduleRetry(initial: initial, attempt: attempt, generation: generation)
            return
        }

        guard text.count <= EditWatcher.maxWatchedCharacters else {
            Log.shared.info("学习：输入框内容过长（\(text.count) 字），本次不观测")
            stop()
            return
        }

        // 第一次成功读到就把它当基线起点，然后继续等粘贴落地。
        // 落地判据用"变了"，不强求包含完整粘贴内容 —— 有些 App 会做自动格式化
        // （补全括号、改写引号），逐字比对会永远等不到。
        // `contains(pasted)` 那条是给自测留的：那边文本一开始就在框里，
        // 不会有"变化"，只看第一条会一直等到超时。
        let landed: Bool
        if let initial {
            landed = !text.isEmpty && text != initial
        } else {
            landed = text.contains(pasted) || (!pasted.isEmpty && text.count > pasted.count)
        }

        guard landed else {
            scheduleRetry(initial: initial ?? text, attempt: attempt, generation: generation)
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

    private func scheduleRetry(initial: String?, attempt: Int, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.settle(initial: initial, attempt: attempt + 1, generation: generation)
        }
    }
    /// 记下"这个 App 读不到输入框"，并**在界面上提示一次**。
    ///
    /// 只是写日志不够：实测用户在一个 App 里连续 10 次听写都读到"不提供文本"，
    /// 两小时里完全不知道学习没在工作 —— 他只看到"改了词没反应"。
    private func reportUnsupported() {
        let app = EditWatcher.focusedAppName()
        Log.shared.info("学习：\(app) 不把输入框内容提供给辅助功能，本次跳过（这个 App 用「纠正最近一次…」）")
        guard !EditWatcher.warnedApps.contains(app) else { return }
        EditWatcher.warnedApps.insert(app)
        onUnsupported?(app)
    }

    /// 轮询等待粘贴落地（文本变得和刚读完时不一样），最多等约 1.8 秒。
    private func settle(initial: String, attempt: Int, generation: Int) {
        guard generation == self.generation else { return }   // 已被新的观测取代
        guard attempt < 12 else {
            Log.shared.info("学习：粘贴后输入框始终没有变化，本次不观测")
            stop()
            return
        }
        guard Date() < deadline else { stop(); return }
        guard let current = EditWatcher.focusedElement(),
              let text = EditWatcher.value(of: current) else {
            reportUnsupported()
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
                self?.settle(initial: initial, attempt: attempt + 1, generation: generation)
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
        generation += 1          // 作废所有在途的 settle 重试
        timer?.invalidate()
        timer = nil
        element = nil
        before = ""
        // 这里**不能**清 pasted / raw：
        // poll() 的流程是 stop() 之后才调 handleChange，而 handleChange 要用
        // self.pasted 去找"我们粘的那段"。清掉它，每一轮改正都会在第一关被丢掉
        // —— 和之前那个 stop() 清空 before 的 bug 是同一类错误。
        // 反正下次 start() 会覆盖它们，没有清的必要。
    }

    // MARK: - 轮询

    private func poll() {
        // 结束路径一定要记日志。
        //
        // 原先只有自测的 verbose 模式才记，生产环境里观测"悄悄结束"——
        // 用户改了词没反应，日志里什么都没有，根本无法定位。
        // 实测（2026-10-01 16:07:35）：观测启动后一片空白，
        // 只能靠猜是超时、焦点跑了、还是判成"不是同一段"。
        let trace = { (message: String) in
            if self.verbose { Log.shared.info("自测轮询：\(message)") }
        }
        let finish = { (reason: String) in
            Log.shared.info("学习：观测结束（\(reason)）")
        }
        guard Date() < deadline else {
            finish("\(Int(EditWatcher.watchSeconds)) 秒窗口内没有检测到修改")
            stop()
            return
        }
        guard let current = EditWatcher.focusedElement() else {
            finish("拿不到焦点元素")
            stop()
            return
        }
        guard let now = EditWatcher.value(of: current) else {
            finish("焦点元素不提供文本")
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
            finish("内容已不是同一段（\(before.count) → \(now.count) 字）—— 换了输入框或文档")
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
            Log.shared.info("学习：改动没有落在我们粘贴的那段里，本次跳过")
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
            Log.shared.info("学习：用户在编辑别的位置，不是改我们的转写，本次跳过")
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
            onCorrection?(corrected, EditDiff.classify(before: pasted, after: corrected))
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
    ///
    /// 只试 `kAXValueAttribute` 是不够的：不同 App 把可编辑文本放在不同地方。
    /// 实测（2026-10-07）用户在一个 App 里连续 10 次听写都读到"不提供文本"，
    /// 整条学习链根本没启动，而日志里只有一句"跳过"。
    ///
    /// 所以按可能性依次尝试，尽量多救回一些 App：
    ///   1. 焦点元素自身的 value（绝大多数 App）
    ///   2. 焦点元素的选中文本（有些把内容放在这里）
    ///   3. 焦点元素的父级 value（文本框外面套一层滚动区的情况）
    ///   4. 焦点元素子树里的第一个文本区（网页输入框常见）
    static func value(of element: AXUIElement, depth: Int = 0) -> String? {
        if let direct = stringAttribute(element, kAXValueAttribute) ?? stringAttribute(element, "AXSelectedText"),
           !direct.isEmpty {
            return direct
        }
        guard depth < 3 else { return nil }

        if let parentRef = attribute(element, kAXParentAttribute),
           CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
            let parent = parentRef as! AXUIElement
            if let up = stringAttribute(parent, kAXValueAttribute), !up.isEmpty { return up }
        }

        if let childrenRef = attribute(element, kAXChildrenAttribute),
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(8) {
                let role = stringAttribute(child, kAXRoleAttribute) ?? ""
                // 只往下找文本类控件，避免在大文档里乱翻
                guard role.contains("Text") || role.contains("Area") || role.contains("Field") else { continue }
                if let text = value(of: child, depth: depth + 1), !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// 焦点元素所在的 App 名。失败日志里必须带上它 ——
    /// 否则用户只会看到"没检测到"，而不知道该换 App 还是换办法。
    static func focusedAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"
    }

    /// 读一个 AX 属性。
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// 读一个字符串类型的 AX 属性。
    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
}
