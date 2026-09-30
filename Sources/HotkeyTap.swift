import AppKit
import CoreGraphics
import ApplicationServices

/// 全局 Fn 键监听。
///
/// 语义：**单击 Fn** 触发一次切换（开始听 / 停止并转写）。
/// 为了不破坏 Fn 本身的功能（Fn+方向键 = Home/End、Fn+Delete 等），
/// 只有"按下到松开不超过阈值、且期间没有按其他键"才算单击。
///
/// 采用 listen-only 事件监听：只观察不吞事件，因此用户需要在
/// 系统设置 → 键盘 里把"按下 🌐 键时"设为"不执行任何操作"，否则
/// 单击 Fn 还会同时弹出表情面板。
final class HotkeyTap {
    /// 单击 Fn。
    var onToggle: (() -> Void)?
    /// 录音期间按 Esc。
    var onCancel: (() -> Void)?

    private var config: VoiceConfig
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnDown = false
    private var fnDownAt: Date?
    private var otherKeyDuringFn = false

    init(config: VoiceConfig) {
        self.config = config
    }

    func update(config: VoiceConfig) {
        self.config = config
    }

    /// @returns 事件监听是否安装成功（失败通常是缺辅助功能权限）。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.shared.error("全局键盘监听安装失败（通常是缺少辅助功能权限）")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.shared.info("Fn 监听已安装")
        return true
    }

    /// 重新安装监听。授权状态变化后需要重建，否则旧 tap 可能收不到事件。
    @discardableResult
    func reinstall() -> Bool {
        stop()
        return start()
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        Log.shared.info("Fn 监听已停止")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在超时或用户输入后会临时关闭 tap，这里立即恢复
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged {
            let isFnDown = event.flags.contains(.maskSecondaryFn)
            if isFnDown && !fnDown {
                fnDown = true
                fnDownAt = Date()
                otherKeyDuringFn = false
            } else if !isFnDown && fnDown {
                fnDown = false
                let held = Date().timeIntervalSince(fnDownAt ?? Date())
                if !otherKeyDuringFn && held <= config.tapMaxSeconds {
                    Log.shared.info("检测到 Fn 单击（按住 \(Int(held * 1000))ms）")
                    DispatchQueue.main.async { [weak self] in self?.onToggle?() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            if keyCode == 63 {
                // 某些键盘把 Fn 报成普通键
                if !fnDown {
                    fnDown = true
                    fnDownAt = Date()
                    otherKeyDuringFn = false
                }
            } else {
                if fnDown { otherKeyDuringFn = true }
                if keyCode == 53 {
                    DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

/// C 事件回调：把 userInfo 里的实例取回来。
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let instance = Unmanaged<HotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return instance.handle(type: type, event: event)
}
