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
    ///
    /// 不是 `private`：菜单提示和诊断文案都从这里取值。
    /// 曾经三处各写各的（代码 60 秒、菜单 60 秒、弹窗 25 秒），
    /// 用户看到的和实际发生的对不上 —— 这种不一致不该靠人记得同步。
    static let watchSeconds: TimeInterval = 60
    private static let pollInterval: TimeInterval = 1.2
    /// 输入框内容超过这个长度就不观测。
    /// 每 1.2 秒读一次全文、还要做一次前后缀比较，编辑器里开着几 MB 文档时
    /// 这个开销不划算；而且那么长的文本里用户改了几个字，本来也不是听写纠正。
    static let maxWatchedCharacters = 20_000

    private var timer: Timer?
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
        // 读不到就"重新声明 + 再读一次"，还不行才等下一轮。
        // 声明那一步是让 Chromium 系（Electron/Edge/飞书）建树的关键。
        let read = EditWatcher.readFocusedText()
        guard let read else {
            scheduleRetry(initial: initial, attempt: attempt, generation: generation)
            return
        }
        let text = read.text

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

        self.before = text
        // 成功也记 App 名 —— 之前只有失败才记，导致"哪些 App 读得到"
        // 事后完全查不出来（日志里 73 次成功一个 App 名都没有）。
        Log.shared.info("学习：开始观测「\(EditWatcher.focusedAppName())」输入框（\(text.count) 字），\(Int(EditWatcher.watchSeconds)) 秒内的改动会被学习")

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


    func stop() {
        generation += 1          // 作废所有在途的 settle 重试
        timer?.invalidate()
        timer = nil
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
    //
    // ## 为什么这里是一串"逐级降级"而不是一个 API 调用
    //
    // **macOS 没有「把用户正在用的那个输入框内容给我」这种 API。**
    // 只有 Accessibility 这一层，而每个 App 怎么暴露文本各不相同：
    //   · 标准 Cocoa 控件          → kAXValueAttribute 直接读得到
    //   · 网页输入框（Chromium 系） → 常常只认按区间取字符串
    //   · Electron / Chromium      → 只有"知道有辅助技术在场"才建完整的树
    //   · 自绘文本（终端、部分编辑器）→ 焦点元素拿不到可用的文本
    //   · 密码框                    → 系统明确标记，**绝不能读**
    //
    // 所以按"从便宜到贵"逐级尝试，并把走到第几级记下来 ——
    // 这样能按 App 统计出"谁需要哪一级"，而不是笼统地说"读不到"。

    /// 读取走到了哪一级。用于日志与按 App 的诊断。
    enum ReadStrategy: String {
        case systemFocus = "系统焦点"
        case appFocus = "App 焦点"
        case appTree = "App 树内查找"
    }

    /// 每个 App 最近一次成功读到所用的级别（App 名 → 级别）。
    private(set) static var strategyByApp: [String: String] = [:]

    /// 系统级焦点元素。绝大多数原生 App 走这条就够了。
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// **App 级**的焦点元素。
    /// 有些实现只在自己那一层报焦点，系统级查询拿不到。
    static func appFocusedElement(pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let app = bounded(AXUIElementCreateApplication(pid))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// **密码框绝不读取。**
    /// 系统会给 `AXSecureTextField` 这个明确的 subrole 标记；
    /// 拿不准的时候一律当密码框处理 —— 学习功能再重要也不能碰用户的密码。
    static func isSecure(_ element: AXUIElement) -> Bool {
        (stringAttribute(element, kAXSubroleAttribute) ?? "") == "AXSecureTextField"
    }

    /// 已经打过招呼的 App（按 pid）。
    private static let announcedLock = NSLock()
    private static var announcedPids = Set<pid_t>()
    /// 声明用的后台队列（串行，避免同时对多个 App 写属性）。
    private static let announceQueue = DispatchQueue(
        label: "ai.deepseek.dsh.voice.announce", qos: .utility
    )

    /// 告诉目标 App「有辅助技术在场，请把你的辅助功能树建起来」。
    ///
    /// Chromium 系（Electron、Edge、飞书、各种桌面端）默认**不构建辅助功能树**，
    /// 只在检测到辅助技术时才建。Electron 官方文档写明：第三方软件可以通过
    /// 设置 `AXManualAccessibility` 属性来打开它。
    ///
    /// **这一条被回退过一次，原因是误判。** 2026-10-08 当时以为是它弄坏了飞书，
    /// 后来查明真凶是飞书自己的 Fn 快捷键抢走麦克风、并一直不释放。
    /// 所以恢复它 —— 它是覆盖 Electron 系那一大类 App 的唯一办法。
    ///
    /// 两条硬约束（都是踩过的坑）：
    ///   · **异步**：这是写另一个 App 的属性，对方忙时同步调用会把我们
    ///     主线程一起拖死。而主线程上还挂着 Fn 事件监听 ——
    ///     后果就是"按 Fn 完全没反应"。
    ///   · **设超时**：默认超时很长，目标无响应时拖到天荒地老。
    static func announceAccessibility(to pid: pid_t) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        announcedLock.lock()
        let alreadyAnnounced = announcedPids.contains(pid)
        if !alreadyAnnounced { announcedPids.insert(pid) }
        announcedLock.unlock()
        guard !alreadyAnnounced else { return }

        announceQueue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(
                Self.bounded(app), "AXManualAccessibility" as CFString, kCFBooleanTrue
            )
        }
    }

    /// 读当前焦点输入框：逐级降级，返回第一个读到的结果。
    static func readFocusedText() -> (element: AXUIElement, text: String)? {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "未知应用"
        let pid = app?.processIdentifier ?? 0

        // ① 系统级焦点元素 —— 最便宜，原生 App 到这就够了
        beginRead()
        if let element = focusedElement(), !isSecure(element), let text = value(of: element) {
            record(strategy: .systemFocus, app: appName)
            return (element, text)
        }

        // ② 顺手向这个 App 打个招呼（异步，不阻塞）。
        //    Chromium 系收到之后才会去建树，而建树是异步的 ——
        //    所以这一步在**录音开始**时就已经做过一次了，这里只是兜底。
        announceAccessibility(to: pid)

        // ③ App 级焦点元素 —— 有些实现只在自己这层报焦点
        nextLevel()
        if let element = appFocusedElement(pid: pid), !isSecure(element), let text = value(of: element) {
            record(strategy: .appFocus, app: appName)
            return (element, text)
        }

        // ④ 在 App 的 AX 树里找一个文本控件 —— 最贵，所以放最后，且严格限量
        nextLevel()
        if let found = findTextElement(inApp: pid) {
            record(strategy: .appTree, app: appName)
            return found
        }

        Log.shared.info("学习：\(appName) 三级读取都没拿到文本（策略=\(ReadStrategy.systemFocus.rawValue)→\(ReadStrategy.appFocus.rawValue)→\(ReadStrategy.appTree.rawValue)）")
        return nil
    }

    private static func record(strategy: ReadStrategy, app: String) {
        let name = strategy.rawValue
        guard strategyByApp[app] != name else { return }
        strategyByApp[app] = name
        // 只在级别变化时记一行，避免刷屏；这一行能直接回答
        // "这个 App 需要走到第几级" —— 之前完全没有这个信息
        Log.shared.info("学习：\(app) 用「\(name)」读到了输入框")
    }

    /// 在 App 的 AX 树里广度优先找一个能读出文本的控件。
    ///
    /// 严格限量：最多访问 40 个元素、只看前 20 个子节点。
    /// 这一步最贵，而且是在主线程上做的 —— 越界就是"Fn 没反应"。
    static func findTextElement(inApp pid: pid_t, limit: Int = 40) -> (AXUIElement, String)? {
        guard pid > 0 else { return nil }
        var queue: [AXUIElement] = [bounded(AXUIElementCreateApplication(pid))]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            guard spendAXCall() else { return nil }   // 预算用尽就放弃，绝不拖主线程
            let element = queue.removeFirst()
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if (role == "AXTextArea" || role == "AXTextField"), !isSecure(element),
               let text = anyText(of: element) {
                return (element, text)
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(20))
            }
        }
        return nil
    }

    /// 读一段区间内的文本。网页输入框（Chromium 系）常常只认这条路。
    static func stringForRange(of element: AXUIElement) -> String? {
        guard spendAXCall() else { return nil }
        var length: Int?
        if let raw = attribute(element, "AXNumberOfCharacters"), let count = raw as? Int, count > 0 {
            length = count
        }
        // 拿不到总长度就按"我们能处理的上限 + 1"问一次 —— 够判断是否过长即可
        let asked = min(length ?? (maxWatchedCharacters + 1), maxWatchedCharacters + 1)
        var range = CFRange(location: 0, length: asked)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success, let text = result as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 把元素上能读到文本的方式逐条试一遍。
    static func anyText(of element: AXUIElement) -> String? {
        if let text = stringAttribute(element, kAXValueAttribute), !text.isEmpty { return text }
        if let text = stringAttribute(element, "AXSelectedText"), !text.isEmpty { return text }
        if let text = stringForRange(of: element) { return text }
        return nil
    }

    /// 读输入框当前文本。读不到（App 不暴露）返回 nil。
    static func value(of element: AXUIElement, depth: Int = 0) -> String? {
        bounded(element)
        if let direct = anyText(of: element) { return direct }
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

    /// 列出这个元素**真正提供**的辅助功能属性名。
    /// 排查"读不到内容"时最有用的一步：能直接看出对方是
    /// 「根本没暴露」还是「暴露在别的属性上」。
    static func attributeNames(of element: AXUIElement) -> [String] {
        bounded(element)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list.sorted()
    }

    /// 跨进程 AX 调用的超时（秒）。
    ///
    /// 这些调用都是在主线程上做的，目标 App 卡住时会**把主线程一起拖死** ——
    /// 而 Fn 事件监听也挂在同一根线程上。0.5 秒：正常 App 的 AX 调用是毫秒级，
    /// 这个值给足余量；卡住的 App 最多让我们等半秒。
    static let axTimeout: Float = 0.5

    /// **一次读取允许发起的 AX 调用总数**（每一级各自计一次）。
    ///
    /// `value(of:)` 会递归找父级和子元素（深度 3、每层最多 8 个），最坏约
    /// 2000 次跨进程调用。只给**单次**调用封顶是不够的。所以还给一整次读取
    /// 加"次数 + 墙钟"双闸：宁可读不到（顶多这次学不到词），
    /// 也绝不能把主线程卡住 —— 那会让 Fn 完全没反应。
    private static let maxAXCallsPerRead = 60
    /// **整条读取链**共享的时间闸（不是每级各一份）。
    ///
    /// 为什么必须是整条链：三级各自 0.25 秒的话，最坏 0.75 秒一次；
    /// 而 settle 在等粘贴落地时会重试最多 24 次 —— 最坏就是十几秒的
    /// 主线程碎片阻塞，而 Fn 事件监听挂在同一根线程上。
    /// 共享一个闸之后，一整次读取最多 0.4 秒，与走几级无关。
    private static let readBudgetSeconds: TimeInterval = 0.4
    private static var axCallsThisRead = 0
    private static var readStartedAt = Date()

    /// 开始一次新的读取（整条链只调一次）：重置次数计数与时间闸。
    static func beginRead() {
        axCallsThisRead = 0
        readStartedAt = Date()
    }

    /// 进入下一级：只重置次数计数，**时间闸继续累计**。
    private static func nextLevel() {
        axCallsThisRead = 0
    }

    /// 记一次调用并判断是否还有预算（次数与时间双闸）。
    private static func spendAXCall() -> Bool {
        guard Date().timeIntervalSince(readStartedAt) < readBudgetSeconds else { return false }
        axCallsThisRead += 1
        return axCallsThisRead <= maxAXCallsPerRead
    }

    /// 给元素设上超时再操作。
    @discardableResult
    static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return element
    }

    /// 读一个 AX 属性。
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard spendAXCall() else { return nil }
        bounded(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// 读一个字符串类型的 AX 属性。
    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
}
