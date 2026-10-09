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
/// 单击 Fn 还会同时弹出输入法切换器。
///
/// ## 为什么跑在**独立线程**上（2026-10-08 的重要修正）
///
/// 原先 run loop source 挂在 `CFRunLoopGetMain()` 上。这带来两个级联故障：
///
/// 1. **主线程一忙就收不到 Fn。** 本 App 会在主线程上做跨进程辅助功能读取
///    （观测用户对转写的修改），目标 App 是 Electron 系时这条路径很慢。
///    实测：在读不到 `AXValue` 的 App（飞书、Edge）里读取会一路递归，
///    主线程被占住 → Fn 事件根本不处理 → 用户看到"这个 App 里按 Fn 没反应"。
///
/// 2. **更糟的是恢复代码也在主线程上。** 回调超时会被系统禁用 tap
///    （`tapDisabledByTimeout`），而恢复它的代码同样跑在主线程 ——
///    主线程正卡着，恢复执行不到，tap 就**永久失效**，只能重启 App。
///
/// 把 source 挂到自己的线程之后这两条都断了：主线程再忙，Fn 照收；
/// 被系统禁用也能立刻恢复。事件里真正需要回主线程的只有"触发切换"那个动作。
final class HotkeyTap {
    /// 单击 Fn。
    var onToggle: (() -> Void)?
    /// 录音期间按 Esc。
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    /// 监听线程自己的 run loop，stop() 时用来停止它。
    private var workerRunLoop: CFRunLoop?

    /// 事件线程与主线程共享的少量状态，都走这把锁。
    private let lock = NSLock()
    private var maxTapSeconds: TimeInterval = 0.45

    // 以下状态只在监听线程上读写，不需要加锁。
    private var fnDown = false
    private var fnDownAt: Date?
    private var otherKeyDuringFn = false
    /// 上一次触发切换的时间，用来吃掉重复事件（见 fireToggle）
    private var lastToggleAt: Date?

    init(config: VoiceConfig) {
        maxTapSeconds = config.tapMaxSeconds
    }

    func update(config: VoiceConfig) {
        lock.lock(); maxTapSeconds = config.tapMaxSeconds; lock.unlock()
    }

    /// 缓存的前台 App 名。
    ///
    /// **事件回调里绝不能去问 WindowServer。** `NSWorkspace.frontmostApplication`
    /// 是跨进程查询，前台是 Electron 应用时可能明显变慢；而 tap 回调一旦超时，
    /// 系统会直接把整个监听禁用 —— 为了一行诊断日志把功能弄坏，不值。
    /// 所以由主线程上的定时器刷新，回调只读缓存。
    static func updateFrontmostApp(_ name: String) {
        nameLock.lock()
        cachedAppNameStorage = name
        nameLock.unlock()
    }

    private static let nameLock = NSLock()
    private static var cachedAppNameStorage = "?"
    private static var cachedFrontmostApp: String {
        nameLock.lock()
        defer { nameLock.unlock() }
        return cachedAppNameStorage
    }

    /// @returns 事件监听是否安装成功（失败通常是缺辅助功能权限）。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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

        // 等监听线程真的把 tap 打开再返回 —— 否则调用方以为"装好了"，
        // 而实际上刚发生的按键会被漏掉。
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let source = self.source else { ready.signal(); return }
            let runLoop = CFRunLoopGetCurrent()
            self.workerRunLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Fn 监听"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
        _ = ready.wait(timeout: .now() + 2.0)

        Log.shared.info("Fn 监听已安装（独立线程）")
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
        if let workerRunLoop, let source {
            CFRunLoopRemoveSource(workerRunLoop, source, .commonModes)
            CFRunLoopStop(workerRunLoop)
        }
        tap = nil
        source = nil
        thread = nil
        workerRunLoop = nil
        Log.shared.info("Fn 监听已停止")
    }

    /// 真正触发一次切换，并**吃掉紧随其后的重复事件**。
    ///
    /// 为什么需要：同一个 Fn 键，有的键盘报 flagsChanged、有的报 keyCode 63，
    /// 还有的两条都报。都报的时候一次物理按压会走两条路径，
    /// 于是一次按压被当成两次 → 开始录音又立刻结束（或反过来）。
    /// 250ms 内的第二次触发一律忽略 —— 人手不可能这么快连按两次。
    private func fireToggle() {
        let now = Date()
        if let last = lastToggleAt, now.timeIntervalSince(last) < 0.25 { return }
        lastToggleAt = now
        // 唯一需要回主线程的动作（改状态、开录音、动界面）
        DispatchQueue.main.async { [weak self] in self?.onToggle?() }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在超时或用户输入后会临时关闭 tap。这行恢复代码现在跑在**独立线程**上，
        // 主线程再卡也能执行 —— 之前它在主线程上，一旦主线程被占住，
        // tap 就一直是禁用状态，Fn 彻底失效且无法自愈。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let why = type == .tapDisabledByTimeout ? "回调超时" : "用户输入"
            Log.shared.error("Fn 监听被系统临时关闭（\(why)），已恢复")
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock(); let limit = maxTapSeconds; lock.unlock()

        if type == .flagsChanged {
            let isFnDown = event.flags.contains(.maskSecondaryFn)
            // 记录每一次 Fn 状态变化（含前台 App），用来区分
            // "事件没到"和"到了但后面的流程断了" —— 这两种在用户看来一样，
            // 日志里必须能分开。
            if isFnDown != fnDown {
                Log.shared.info("Fn \(isFnDown ? "按下" : "松开")（前台：\(HotkeyTap.cachedFrontmostApp)）")
            }
            if isFnDown && !fnDown {
                fnDown = true
                fnDownAt = Date()
                otherKeyDuringFn = false
            } else if !isFnDown && fnDown {
                fnDown = false
                let held = Date().timeIntervalSince(fnDownAt ?? Date())
                if !otherKeyDuringFn && held <= limit {
                    Log.shared.info("检测到 Fn 单击（按住 \(Int(held * 1000))ms）")
                    fireToggle()
                } else {
                    // **被判定拒绝时一定要出声。** 原先静默丢弃，"按住太久"
                    // 和"事件根本没到"在用户看来都是"按 Fn 没反应"，
                    // 日志里却只有后者有痕迹，排查时会把判定层误判成事件层。
                    let why = otherKeyDuringFn
                        ? "期间按了其他键"
                        : "按住 \(Int(held * 1000))ms 超过 \(Int(limit * 1000))ms"
                    Log.shared.info("Fn 未触发（\(why)）")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // 有些键盘把 Fn 当**普通按键**上报（keyCode 63），而不是 flagsChanged。
        // 这条路径必须成对处理：只处理 keyDown 的话 fnDown 永远是 true，
        // 于是**第一次之后 Fn 就再也不响应了**（症状："按 Fn 结束不了录音"）。
        if type == .keyDown {
            if keyCode == 63 {
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
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp, keyCode == 63, fnDown {
            fnDown = false
            let held = Date().timeIntervalSince(fnDownAt ?? Date())
            if !otherKeyDuringFn && held <= limit {
                Log.shared.info("检测到 Fn 单击（按住 \(Int(held * 1000))ms）")
                fireToggle()
            } else {
                let why = otherKeyDuringFn
                    ? "期间按了其他键"
                    : "按住 \(Int(held * 1000))ms 超过 \(Int(limit * 1000))ms"
                Log.shared.info("Fn 未触发（\(why)）")
            }
            return Unmanaged.passUnretained(event)
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
