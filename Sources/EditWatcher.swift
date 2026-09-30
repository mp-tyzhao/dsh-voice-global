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
    /// 观测窗口。太短会漏掉"想一会儿再改"，太长会白轮询。
    private static let watchSeconds: TimeInterval = 25
    private static let pollInterval: TimeInterval = 1.2

    private var timer: Timer?
    private var element: AXUIElement?
    private var before: String = ""
    private var pasted: String = ""
    private var raw: String = ""
    private var deadline = Date()

    private let config: VoiceConfig
    private let sidecar: Sidecar
    /// 学到新词时回调，用来在界面上告诉用户"学到东西了"
    var onLearned: (([String]) -> Void)?
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
        self.before = text
        self.pasted = pasted
        self.raw = raw
        self.deadline = Date().addingTimeInterval(EditWatcher.watchSeconds)
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
        guard Date() < deadline else {
            stop()
            return
        }
        // 焦点跑了说明用户在忙别的，不再观测
        guard let current = EditWatcher.focusedElement(),
              let stillSame = element.map({ CFEqual($0, current) }), stillSame else {
            stop()
            return
        }
        guard let now = EditWatcher.value(of: current), now != before else { return }

        stop()
        handleChange(from: before, to: now)
    }

    /// 输入框内容变了：确认改动落在我们粘贴的那段里，再交给学习。
    private func handleChange(from old: String, to new: String) {
        // 1. 我们粘的那段得还在（用户可能把它删了，那不算纠正）
        guard let pastedRange = old.range(of: pasted), !pasted.isEmpty else { return }

        // 2. 找出改动的区间
        let (prefix, suffix) = EditDiff.commonEdges(old, new)
        guard prefix < old.count - suffix else { return }   // 纯删除到什么都不剩

        let changeStart = old.index(old.startIndex, offsetBy: prefix)
        let changeEnd = old.index(old.endIndex, offsetBy: -suffix)
        guard changeStart < changeEnd else { return }
        // 改动必须与粘贴段相交，否则是用户在编辑别的地方
        guard changeStart < pastedRange.upperBound, changeEnd > pastedRange.lowerBound else { return }

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

        sidecar.learn(raw: oldWindow, corrected: newWindow, config: config) { [weak self] added in
            guard !added.isEmpty else { return }
            Log.shared.info("学到新词：\(added.joined(separator: "、"))")
            self?.onLearned?(added)
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
