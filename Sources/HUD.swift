import AppKit

/// 屏幕底部的极简状态条。
///
/// 关键约束：**绝不能抢焦点**——一旦抢走焦点，⌘V 就粘到我们自己身上了。
/// 因此用 nonactivating 面板 + ignoresMouseEvents，并且只用 orderFrontRegardless 显示。
final class HUD {
    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var levelBar: LevelBar?
    private var hideWorkItem: DispatchWorkItem?

    /// 是否正在录音。录音期间浮窗显示的是"正在聆听 + 电平条"，
    /// 这条信息比任何提示都重要，不能被顶掉。
    private var isRecording = false
    /// 录音期间浮窗应该显示的标题/详情，用于自愈时恢复。
    private var recordingTitle = "正在聆听…"
    private var recordingDetail = ""
    /// 录音期间被推迟的提示，等录音结束再补显示。
    private var pendingFlash: (title: String, detail: String, seconds: Double)?
    /// 最近一次收到电平的时刻。
    private var lastLevelAt = Date.distantPast

    /// **是不是真的还在录音。**
    ///
    /// 不光看 isRecording 这个标志，还要求"电平最近还在刷新"——
    /// 电平每秒被推进 30 次，超过 2 秒没动静就说明录音早就结束了
    /// （取消、录音过短、异常退出等路径）。
    ///
    /// 加这一层是因为：靠"每个结束路径都记得调 endRecording()"太脆 ——
    /// 实测漏了两条（Esc 取消、录音过短），结果浮窗卡在"正在聆听"、
    /// 用户以为 Esc 没反应。有了这个兜底，即使再漏一条也不会卡住。
    private var isActivelyRecording: Bool {
        isRecording && Date().timeIntervalSince(lastLevelAt) < 2.0
    }

    private let width: CGFloat = 320
    private let height: CGFloat = 64

    func show(title: String, detail: String, recording: Bool) {
        let panel = ensurePanel()
        isRecording = recording
        if recording {
            recordingTitle = title
            recordingDetail = detail
        }
        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail
        levelBar?.isHidden = !recording
        levelBar?.level = 0
        cancelPendingHide()

        // 放在**鼠标所在的那块屏幕**上。
        //
        // 原先固定用 NSScreen.main（键盘焦点屏）。接了外接显示器之后，
        // 用户看着的那块屏可能不是 main —— 浮窗就"消失"了（其实在另一块屏上）。
        // 鼠标位置是"用户此刻在看哪"的最好近似。
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let origin = CGPoint(
                x: frame.midX - width / 2,
                y: frame.minY + 96
            )
            panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // 记日志：浮窗"看不见"时要能区分是没显示、还是显示在别处
        Log.shared.info("浮窗：\(title) → \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)) "
            + "屏 \(Int(screen?.frame.width ?? 0))x\(Int(screen?.frame.height ?? 0)) "
            + "可见=\(panel.isVisible) 屏数=\(NSScreen.screens.count)")

        // 录音刚结束：把录音期间被推迟的提示补上。
        if !recording { flushPendingFlash() }
    }

    /// 结束录音状态，并补显示被推迟的提示。
    ///
    /// **取消、录音过短这类"没有后续浮窗"的路径必须调用它。**
    ///
    /// 不调用的话 `isRecording` 会一直是 true：flash 被无限推迟，浮窗停在
    /// "正在聆听…"不动，用户按 Esc 之后界面毫无反应 —— 看起来就是"Esc 没用"。
    /// 实测踩过两次（2026-10-09 13:32、2026-10-10 07:31，日志里都是
    /// 「（录音中）推迟提示：已取消」然后再无下文）。
    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        flushPendingFlash()
    }

    /// 把录音期间被推迟的提示补上。
    /// 延后 2.2 秒，让"已输入/没听清"这类结果提示先显示 ——
    /// 那才是用户此刻最关心的，学习提示排它后面。
    private func flushPendingFlash() {
        guard let pending = pendingFlash else { return }
        pendingFlash = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, !self.isRecording else { return }
            self.flash(title: pending.title, detail: pending.detail, seconds: pending.seconds)
        }
    }

    func setLevel(_ level: Float) {
        lastLevelAt = Date()
        levelBar?.level = level
        // 录音期间顺带做两件自愈：
        //
        // 1. **浮窗还在不在**。用户报过"浮窗没了，看不到是不是在输入"，
        //    重启才好 —— 但产品不能靠重启。系统休眠唤醒、别的 App 抢占、
        //    或者我们自己某处误隐藏都会让它消失，而那时用户正在说话。
        // 2. **标题还是不是"正在聆听"**。提示（flash）会把标题改掉、把电平条
        //    藏起来；一旦被顶掉，用户看到的就是一条过期的提示。
        //    实测日志：17:35:42 开始录音 → :43 正在聆听 → :44 被"学不到"顶掉。
        //
        // 这个函数在录音期间每秒被调用 30 次，拿它当自愈点几乎不花代价。
        guard let panel else { return }
        if titleLabel?.stringValue != recordingTitle || detailLabel?.stringValue != recordingDetail
            || levelBar?.isHidden == true {
            titleLabel?.stringValue = recordingTitle
            detailLabel?.stringValue = recordingDetail
            levelBar?.isHidden = false
            Log.shared.info("浮窗：录音状态被顶掉了，已恢复")
        }
        guard !panel.isVisible else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        Log.shared.info("浮窗：被隐藏了，已重新显示")
    }

    /// 显示一个短暂的成功/失败提示后自动隐藏。
    ///
    /// **录音期间不覆盖**"正在聆听"浮窗 —— 那时电平条和录音状态比提示重要，
    /// 而且提示一到期会把整个浮窗藏掉。改记下来，等录音结束再补显示。
    func flash(title: String, detail: String, seconds: Double = 1.6) {
        guard !isActivelyRecording else {
            pendingFlash = (title, detail, seconds)
            Log.shared.info("浮窗：（录音中）推迟提示：\(title)")
            return
        }
        // 录音状态其实已经结束、只是标志没清 —— 顺手清掉，别把提示憋住
        if isRecording { isRecording = false }
        show(title: title, detail: detail, recording: false)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        cancelPendingHide()
        panel?.orderOut(nil)
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        let bar = LevelBar(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(detail)
        effect.addSubview(bar)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 13),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 7),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])

        panel.contentView = effect
        self.panel = panel
        titleLabel = title
        detailLabel = detail
        levelBar = bar
        return panel
    }
}

/// 录音电平条：只在录音时显示。
private final class LevelBar: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        background.fill()

        let clamped = CGFloat(max(0, min(1, level)))
        guard clamped > 0.01 else { return }
        let filled = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
