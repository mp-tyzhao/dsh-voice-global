import AppKit
import AVFoundation

/// 全局听写控制器：Fn 单击 → 录音 → 本地转写 + 清理 → 落到当前光标处。
final class VoiceController {
    enum State {
        case idle
        case recording
        case transcribing

        var icon: String {
            switch self {
            case .idle: return "mic"
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            }
        }

        var label: String {
            switch self {
            case .idle: return "就绪"
            case .recording: return "录音中"
            case .transcribing: return "转写中"
            }
        }
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?
    var onTranscript: ((Sidecar.Result) -> Void)?

    private(set) var config: VoiceConfig
    private let recorder = Recorder()
    private let sidecar = Sidecar()
    private let hud = HUD()
    private var hotkey: HotkeyTap
    private var levelTimer: Timer?
    private var idleTimer: Timer?
    private(set) var lastTranscript: String = ""
    private(set) var lastError: String?

    init(config: VoiceConfig) {
        self.config = config
        self.hotkey = HotkeyTap(config: config)
        hotkey.onToggle = { [weak self] in self?.toggle() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
    }

    /// 启动识别服务与热键监听。
    func start(completion: ((Bool, String) -> Void)? = nil) {
        sidecar.start(config: config) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                let installed = self.hotkey.start()
                completion?(installed, installed ? "就绪" : "缺少辅助功能权限")
            case .failure(let error):
                self.lastError = error.localizedDescription
                Log.shared.error("识别服务启动失败：\(error)")
                // 识别服务没起来时仍然安装热键，用户至少能看到明确报错
                _ = self.hotkey.start()
                completion?(false, "\(error)")
            }
        }
    }

    func stop() {
        levelTimer?.invalidate()
        idleTimer?.invalidate()
        hotkey.stop()
        sidecar.stop()
    }

    /// 一段空闲后释放识别进程（模型常驻约 900MB，重载仅 0.4 秒）。
    private func scheduleIdleUnload() {
        idleTimer?.invalidate()
        guard config.idleUnloadSeconds > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double(config.idleUnloadSeconds), repeats: false) { [weak self] _ in
            guard let self, self.state == .idle else { return }
            Log.shared.info("空闲 \(self.config.idleUnloadSeconds)s，卸载识别模型")
            self.sidecar.stop()
        }
    }

    /// 开始录音前先把识别进程拉起来；用户说完时它已经就绪。
    private func prewarmSidecar() {
        idleTimer?.invalidate()
        sidecar.start(config: config) { result in
            if case .failure(let error) = result {
                Log.shared.error("预热识别服务失败：\(error)")
            }
        }
    }

    /// 单击 Fn 的切换逻辑。
    func toggle() {
        switch state {
        case .idle:
            beginRecording()
        case .recording:
            endRecordingAndTranscribe()
        case .transcribing:
            Log.shared.info("转写中，忽略本次 Fn 单击")
        }
    }

    /// Esc：放弃当前录音。
    func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        levelTimer?.invalidate()
        state = .idle
        scheduleIdleUnload()
        hud.flash(title: "已取消", detail: "本次录音已丢弃", seconds: 1.0)
    }

    func reload(config: VoiceConfig) {
        self.config = config
        hotkey.update(config: config)
        // 识别进程是按旧配置（模型路径、线程数、润色端点）启动的，
        // 必须停掉才会用新配置重启；下一次录音开始时会自动预热。
        if state == .idle {
            sidecar.stop()
        }
        Log.shared.info("配置已重载；识别进程将在下次录音时按新配置启动")
    }

    /// 从菜单切换清理模式，并写回配置文件。
    func setCleanupMode(_ mode: String) {
        var updated = config
        updated.cleanup = mode
        if mode == "llm" { updated.llm.enabled = true }
        ConfigStore.save(updated)
        reload(config: updated)
    }

    /// 授权之后重新尝试安装热键监听（无需重启应用）。
    @discardableResult
    func ensureHotkey(forceReinstall: Bool = false) -> Bool {
        forceReinstall ? hotkey.reinstall() : hotkey.start()
    }

    /// 给用户在 HUD 上一条可见反馈。
    func notify(title: String, detail: String) {
        guard config.showHUD else { return }
        hud.flash(title: title, detail: detail, seconds: 2.2)
    }

    // MARK: - 录音

    private func beginRecording() {
        // 即使上一次空闲把识别进程卸了，这里也会立刻重新拉起；
        // 录音本身不受影响，等用户说完时模型早就加载好了。
        prewarmSidecar()

        guard Recorder.permissionStatus == .authorized else {
            Recorder.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.lastError = "没有麦克风权限"
                    self.hud.flash(title: "缺少麦克风权限", detail: "系统设置 → 隐私与安全性 → 麦克风", seconds: 3)
                }
            }
            return
        }

        do {
            try recorder.start()
        } catch {
            lastError = "\(error)"
            Log.shared.error("录音启动失败：\(error)")
            hud.flash(title: "无法录音", detail: "\(error)", seconds: 3)
            return
        }

        state = .recording
        if config.playSounds { NSSound(named: NSSound.Name("Tink"))?.play() }
        if config.showHUD {
            hud.show(title: "正在聆听…", detail: "再按一次 Fn 结束并转写 · Esc 取消", recording: true)
        }
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.config.showHUD else { return }
            self.hud.setLevel(self.recorder.level)
        }
    }

    private func endRecordingAndTranscribe() {
        levelTimer?.invalidate()
        guard let wav = recorder.stop() else {
            state = .idle
            hud.flash(title: "太短了", detail: "没有录到有效语音", seconds: 1.4)
            return
        }
        if config.playSounds { NSSound(named: NSSound.Name("Pop"))?.play() }

        state = .transcribing
        if config.showHUD {
            hud.show(title: "转写中…", detail: "本地 SenseVoice", recording: false)
        }

        let url = Paths.tmp.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        do {
            try wav.write(to: url)
        } catch {
            lastError = "临时文件写入失败"
            state = .idle
            hud.flash(title: "写入失败", detail: "\(error)", seconds: 3)
            return
        }

        let started = Date()
        sidecar.transcribe(wav: url, config: config) { [weak self] result in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: url) }

            switch result {
            case .success(let value):
                self.state = .idle
                self.lastTranscript = value.text
                self.lastError = nil
                self.onTranscript?(value)
                Log.shared.info("转写完成 raw=\(value.raw.debugDescription) text=\(value.text.debugDescription) hits=\(value.hits) 端到端=\(Int(Date().timeIntervalSince(started) * 1000))ms")

                guard !value.text.isEmpty else {
                    self.hud.flash(title: "没听清", detail: "这次没有识别到文字", seconds: 1.6)
                    return
                }
                self.scheduleIdleUnload()
                Injector.paste(value.text, config: self.config) { pasted in
                    if pasted {
                        let saved = value.raw == value.text ? "未改动" : "已清理 \(value.hits.count) 处"
                        self.hud.flash(title: "已输入", detail: "\(saved) · \(value.text.prefix(28))", seconds: 1.4)
                    } else if !Injector.isTrusted {
                        self.hud.flash(title: "已复制到剪贴板", detail: "授予辅助功能权限后可直接粘贴", seconds: 3.5)
                    } else {
                        self.hud.flash(title: "粘贴失败", detail: "文本已留在剪贴板", seconds: 3)
                    }
                }
            case .failure(let error):
                self.state = .idle
                self.lastError = "\(error)"
                self.scheduleIdleUnload()
                Log.shared.error("转写失败：\(error)")
                if self.config.playSounds { NSSound(named: NSSound.Name("Basso"))?.play() }
                self.hud.flash(title: "转写失败", detail: "\(error)", seconds: 3.5)
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: VoiceController?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护必须放在最前面：两份 App 同时跑会各自监听 Fn、各自粘贴一次，
        // 用户看到的就是"每句话被录入两遍"。放在这里也意味着重复实例在安装任何
        // 监听之前就退出了，不会污染正在运行的那一份。
        let lockPath = Paths.home.appendingPathComponent("instance.lock").path
        guard SingleInstance.acquire(lockPath: lockPath) else {
            let other = SingleInstance.otherInstance()
            Log.shared.info("已有另一个实例在运行（pid=\(other?.processIdentifier ?? -1)），本实例直接退出，避免重复粘贴")
            other?.activate()
            showAlert(
                title: "DSH Voice 已经在运行",
                body: """
                检测到另一个 DSH Voice 正在运行：
                \(other?.bundleURL?.path ?? "（位置未知）")

                两份同时运行会让每一句话都被录入两遍。请只保留一份
                （建议保留「应用程序」里的那份），关掉另一份后重新打开。
                """
            )
            exit(0)
        }

        let config = ConfigStore.load()
        let controller = VoiceController(config: config)
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "DSH Voice")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "DSH Voice Global —— 单击 Fn 开始/结束听写"

        controller.onStateChange = { [weak self] state in
            self?.statusItem?.button?.image = NSImage(systemSymbolName: state.icon, accessibilityDescription: state.label)
            self?.statusItem?.button?.image?.isTemplate = true
            self?.rebuildMenu(state: state)
        }
        controller.onTranscript = { [weak self] _ in self?.rebuildMenu(state: .idle) }

        controller.start { [weak self] ready, message in
            Log.shared.info("启动结果：ready=\(ready) message=\(message)")
            guard let self else { return }
            if !ready, Injector.isTrusted {
                self.controller?.stop()
                self.showAlert(
                    title: "DSH Voice 未能就绪",
                    body: message + "\n\n请检查：\n· 系统设置 → 隐私与安全性 → 麦克风\n· 日志：\(Paths.log.path)"
                )
            }
            self.rebuildMenu(state: .idle)
        }

        // 粘贴必须由已授权的进程合成 ⌘V；没有权限就立刻引导一次，
        // 并开始轮询——用户授权后无需重启，热键会重新安装。
        if !Injector.isTrusted {
            Log.shared.info("辅助功能权限未授予：已发起系统引导，并开始轮询（授权后自动启用）")
            Injector.requestTrust()
            startPermissionWatch()
        } else {
            Log.shared.info("辅助功能权限已就绪")
        }
    }

    /// 等辅助功能授权到位后自动启用监听。
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self, Injector.isTrusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            // 授权前后 tap 的可达性会变，强制重建一次
            let installed = self.controller?.ensureHotkey(forceReinstall: true) ?? false
            Log.shared.info("辅助功能权限已授予，重建监听：\(installed)")
            if installed {
                NSSound(named: NSSound.Name("Glass"))?.play()
                self.controller?.notify(title: "DSH Voice 就绪", detail: "单击 Fn 开始说话，再按一次结束")
            }
            self.rebuildMenu(state: self.controller?.state ?? .idle)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private func rebuildMenu(state: VoiceController.State) {
        guard let controller else { return }
        let menu = NSMenu()

        let status = NSMenuItem(title: "状态：\(state.label)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let hint = NSMenuItem(title: "单击 Fn 开始 · 再按一次结束", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        if !Injector.isTrusted {
            let permission = NSMenuItem(title: "⚠️ 授予辅助功能权限", action: #selector(openAccessibility), keyEquivalent: "")
            permission.target = self
            menu.addItem(permission)
            menu.addItem(.separator())
        }

        if !controller.lastTranscript.isEmpty {
            let last = NSMenuItem(title: "最近一次：\(controller.lastTranscript.prefix(30))", action: #selector(copyLast), keyEquivalent: "")
            last.target = self
            menu.addItem(last)
            menu.addItem(.separator())
        }

        let cleanupItem = NSMenuItem(title: "清理模式", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let modes: [(String, String)] = [
            ("off", "只转写（不清理）"),
            ("rules", "规则清理（纯离线）"),
            ("llm", "规则 + 模型润色"),
        ]
        for (mode, title) in modes {
            let item = NSMenuItem(title: title, action: #selector(selectCleanup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = controller.config.cleanup == mode ? .on : .off
            submenu.addItem(item)
        }
        cleanupItem.submenu = submenu
        menu.addItem(cleanupItem)

        let llm = controller.config.llm
        let llmHint = NSMenuItem(
            title: llm.enabled ? "润色模型：\(llm.model)" : "润色模型：未启用",
            action: nil, keyEquivalent: ""
        )
        llmHint.isEnabled = false
        menu.addItem(llmHint)
        menu.addItem(.separator())

        add(menu, title: "打开配置", action: #selector(openConfig))
        add(menu, title: "打开日志", action: #selector(openLog))
        add(menu, title: "重新加载配置", action: #selector(reloadConfig))
        add(menu, title: "检查权限与服务", action: #selector(runCheck))
        menu.addItem(.separator())
        add(menu, title: "退出", action: #selector(quit))

        statusItem?.menu = menu
    }

    private func add(_ menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Paths.config)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func reloadConfig() {
        controller?.reload(config: ConfigStore.load())
        rebuildMenu(state: controller?.state ?? .idle)
    }

    @objc private func selectCleanup(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        controller?.setCleanupMode(mode)
        rebuildMenu(state: controller?.state ?? .idle)
    }

    @objc private func copyLast() {
        guard let text = controller?.lastTranscript, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openAccessibility() {
        Injector.requestTrust()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func runCheck() {
        let report = Diagnostics.collect(config: controller?.config ?? VoiceConfig())
        showAlert(title: "自检结果", body: report)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 自检

enum Diagnostics {
    /// 收集一份可粘贴给他人排查的报告（不含任何密钥）。
    static func collect(config: VoiceConfig) -> String {
        let modelRoot = config.resolvedModelRoot
        let model = "\(modelRoot)/sensevoice-onnx/model.int8.onnx"
        let tokens = "\(modelRoot)/sensevoice-onnx/tokens.txt"
        let vad = "\(modelRoot)/silero/silero_vad.onnx"

        func mark(_ condition: Bool) -> String { condition ? "✅" : "❌" }

        var lines: [String] = []
        lines.append("\(mark(Recorder.permissionStatus == .authorized)) 麦克风权限：\(Recorder.permissionStatus.rawValue == 3 ? "已授权" : "未授权")")
        lines.append("\(mark(Injector.isTrusted)) 辅助功能权限（模拟 ⌘V 必需）：\(Injector.isTrusted ? "已授权" : "未授权")")
        lines.append("ℹ️ 若 --listen 收不到 Fn 事件，还需在「输入监控」里勾选本应用")

        // 模型来源：让用户/Agent 一眼看出是"随包自带"还是"复用已有"还是"需要下载"
        let ownRoot = Paths.models.path
        let source: String
        switch modelRoot {
        case let root where root == Paths.bundledModelRoot: source = "随应用包自带"
        case ownRoot: source = "自带目录"
        case Paths.userHome.appendingPathComponent(".dsh/speech-to-text/sensevoice/models").path: source = "复用 DSH 缓存（未重复下载）"
        default: source = "自定义路径"
        }
        lines.append("\(mark(FileManager.default.fileExists(atPath: model))) 识别模型（\(source)）：\(model)")
        lines.append("\(mark(FileManager.default.fileExists(atPath: tokens))) 词表：\(tokens)")
        lines.append("\(mark(FileManager.default.fileExists(atPath: vad))) VAD：\(vad)")
        lines.append("清理模式：\(config.cleanup)")
        lines.append("润色模型：\(config.llm.enabled ? config.llm.model : "未启用")")
        let keySource: String
        if !config.llm.apiKey.isEmpty {
            keySource = "config.json 内联"
        } else if FileManager.default.fileExists(atPath: Paths.envFile.path) {
            keySource = "~/.voice-global/.env"
        } else if !config.llm.apiKeyCommand.isEmpty {
            keySource = "自定义命令"
        } else {
            keySource = "未配置（纯离线模式仍可用）"
        }
        lines.append("密钥来源：\(keySource)")
        lines.append("数据目录：\(Paths.home.path)")
        lines.append("日志：\(Paths.log.path)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 入口

/// 打印用法。
func printUsage() {
    print("""
    DSH Voice Global —— 全局语音听写（单击 Fn 开始 / 再按结束）

    用法：
      DSHVoice                 启动菜单栏常驻服务
      DSHVoice --check         打印权限与依赖自检
      DSHVoice --listen [秒]    探测 Fn 事件是否真的能收到（默认 15 秒）
      DSHVoice --selftest [秒]  录音若干秒并输出转写结果（默认 4 秒）
      DSHVoice --inject "文本"   测试把文本粘贴到当前应用
      DSHVoice --help          显示本帮助
    """)
}

/// 驱动主线程 RunLoop 直到条件满足或超时（CLI 子命令用）。
func pumpRunLoop(timeout: TimeInterval, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

func runCheck() {
    let config = ConfigStore.load()
    print(Diagnostics.collect(config: config))

    let sidecar = Sidecar()
    var ready = false
    var failure: String?
    sidecar.start(config: config) { result in
        switch result {
        case .success: ready = true
        case .failure(let error): failure = "\(error)"
        }
    }
    pumpRunLoop(timeout: 30) { ready || failure != nil }
    if ready {
        print("✅ 识别服务：就绪")
    } else {
        print("❌ 识别服务：\(failure ?? "30 秒内未就绪")")
    }
    sidecar.stop()
}

func runSelfTest(seconds: Double) {
    let config = ConfigStore.load()
    let recorder = Recorder()
    let sidecar = Sidecar()
    var phase = "启动识别服务"
    var finished = false
    var exitCode: Int32 = 0
    let startedAt = Date()

    guard Recorder.permissionStatus == .authorized else {
        print("❌ 没有麦克风权限，无法自检")
        exit(2)
    }

    sidecar.start(config: config) { result in
        switch result {
        case .failure(let error):
            print("❌ 识别服务启动失败：\(error)")
            finished = true
            exitCode = 1
        case .success:
            do {
                try recorder.start()
                phase = "录音 \(seconds) 秒"
                print("🎙  录音中（\(seconds) 秒）…")
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    phase = "转写"
                    guard let wav = recorder.stop(), !wav.isEmpty else {
                        print("❌ 没有录到有效音频")
                        finished = true
                        exitCode = 1
                        return
                    }
                    let url = Paths.tmp.appendingPathComponent("selftest.wav")
                    try? wav.write(to: url)
                    sidecar.transcribe(wav: url, config: config) { result in
                        switch result {
                        case .success(let value):
                            let payload: [String: Any] = [
                                "seconds": (wav.count - 44) / 32000,
                                "raw": value.raw,
                                "text": value.text,
                                "hits": value.hits,
                                "asrMs": value.asrMilliseconds,
                                "endToEndMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                               let text = String(data: data, encoding: .utf8) {
                                print(text)
                            }
                        case .failure(let error):
                            print("❌ 转写失败：\(error)")
                            exitCode = 1
                        }
                        finished = true
                    }
                }
            } catch {
                print("❌ 录音启动失败：\(error)")
                finished = true
                exitCode = 1
            }
        }
    }

    pumpRunLoop(timeout: seconds + 90) { finished }
    sidecar.stop()
    if !finished {
        print("❌ 自检超时（当前阶段：\(phase)）")
        exitCode = 1
    }
    exit(exitCode)
}

/// Fn 探测模式：打印真实到达的键盘事件，用来区分"权限没给"和"按键没配对"。
private var listenFnDownCount = 0
private var listenTapCount = 0
private var listenFnDownAt: Date?
private var listenOtherKey = false

private func listenCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("⚠️  监听被系统临时关闭（超时/用户输入），已请求恢复")
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
        let isFn = event.flags.contains(.maskSecondaryFn)
        if isFn {
            listenFnDownCount += 1
            listenFnDownAt = Date()
            listenOtherKey = false
            print("↓ Fn 按下 (flags=\(event.flags.rawValue))")
        } else {
            let held = listenFnDownAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            if !listenOtherKey && held <= 450 { listenTapCount += 1 }
            print("↑ Fn 松开 (按住 \(Int(held))ms)")
        }
    } else if type == .keyDown {
        if keyCode == 63 {
            listenFnDownCount += 1
            listenFnDownAt = Date()
            listenOtherKey = false
            print("↓ Fn 按下（以 keyDown 上报）")
        } else {
            listenOtherKey = true
            print("· 其他按键 keyCode=\(keyCode)")
        }
    }
    return Unmanaged.passUnretained(event)
}

func runListenTest(seconds: Double) {
    print("辅助功能权限：\(Injector.isTrusted ? "已授权" : "未授权")")
    let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: listenCallback,
        userInfo: nil
    ) else {
        print("❌ 无法安装键盘监听：缺辅助功能权限")
        exit(2)
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("监听 \(Int(seconds)) 秒 —— 请单击一次 Fn（按一下松开）…\n")
    pumpRunLoop(timeout: seconds) { false }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)

    print("")
    if listenFnDownCount == 0 {
        print("❌ 没有收到任何 Fn 事件。可能是：")
        print("   1) 辅助功能 / 输入监控 权限未生效（监听已装上但事件不会投递）")
        print("      系统设置 → 隐私与安全性 → 辅助功能 和 输入监控，都勾选 DSH Voice")
        print("   2) 键盘把 Fn 交给了系统（键盘设置里把「按下 🌐 键时」设为不执行任何操作）")
        exit(1)
    }
    print("✅ 收到 \(listenFnDownCount) 次 Fn 按下，识别为单击 \(listenTapCount) 次")
    print(listenTapCount > 0 ? "→ 单击语义可用，App 会按这个信号开始/结束听写" : "→ 事件到了，但都不满足单击判定（按太久或期间按了其他键）")
}

/// 循环压测：start → transcribe → stop（模拟空闲卸载）→ 再 start。
/// 用来验证"模型卸载后能被下一次听写重新拉起"这条路径。
func runCycleTest(wavPath: String, rounds: Int) {
    let config = ConfigStore.load()
    let sidecar = Sidecar()
    let url = URL(fileURLWithPath: wavPath)
    var index = 0
    var failures = 0
    var finished = false

    func step() {
        guard index < rounds else {
            print(failures == 0
                ? "✅ \(rounds) 轮 启动→转写→卸载→重启 全部通过"
                : "❌ \(rounds) 轮中有 \(failures) 轮失败")
            finished = true
            return
        }
        index += 1
        let round = index
        sidecar.start(config: config) { startResult in
            if case .failure(let error) = startResult {
                print("❌ 第 \(round) 轮启动失败：\(error)")
                failures += 1
                step()
                return
            }
            sidecar.transcribe(wav: url, config: config) { result in
                switch result {
                case .success(let value):
                    print("✓ 第 \(round) 轮：asr=\(value.asrMilliseconds)ms text=\(value.text)")
                case .failure(let error):
                    print("❌ 第 \(round) 轮转写失败：\(error)")
                    failures += 1
                }
                sidecar.stop()  // 模拟空闲卸载
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { step() }
            }
        }
    }

    step()
    pumpRunLoop(timeout: 240) { finished }
    exit(failures == 0 ? 0 : 1)
}

func runInject(text: String) {
    let config = ConfigStore.load()
    guard Injector.isTrusted else {
        print("❌ 缺少辅助功能权限，无法模拟 ⌘V")
        exit(2)
    }
    var pasted = false
    Injector.paste(text, config: config) { ok in pasted = ok }
    pumpRunLoop(timeout: 5) { pasted }
    print(pasted ? "✅ 已发送 ⌘V：\(text)" : "❌ 粘贴失败")
    exit(pasted ? 0 : 1)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

if arguments.contains("--check") {
    runCheck()
    exit(0)
}

if let index = arguments.firstIndex(of: "--selftest") {
    let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 4 : 4
    runSelfTest(seconds: seconds)
}

if let index = arguments.firstIndex(of: "--listen") {
    let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 15 : 15
    runListenTest(seconds: seconds)
    exit(0)
}

if let index = arguments.firstIndex(of: "--cycle-test") {
    guard index + 1 < arguments.count else {
        print("❌ --cycle-test 需要 WAV 路径")
        exit(2)
    }
    let rounds = index + 2 < arguments.count ? Int(arguments[index + 2]) ?? 3 : 3
    runCycleTest(wavPath: arguments[index + 1], rounds: rounds)
}

if let index = arguments.firstIndex(of: "--inject") {
    guard index + 1 < arguments.count else {
        print("❌ --inject 需要文本参数")
        exit(2)
    }
    runInject(text: arguments[index + 1])
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
