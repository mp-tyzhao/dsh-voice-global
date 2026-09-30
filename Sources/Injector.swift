import AppKit
import ApplicationServices

/// 把文本送进当前聚焦的应用。
///
/// 做法是业界标准套路：把文本写进剪贴板 → 合成一次 ⌘V → 稍后恢复原剪贴板。
/// 之所以不用 Accessibility 直接写控件值：那样对 Electron / 浏览器 / 终端
/// 的可编辑区域支持差异极大，而 ⌘V 在所有应用里都一致（且能正确覆盖选中内容）。
///
/// 前提是辅助功能权限：合成键盘事件必须由 AXIsProcessTrusted 的应用发出。
enum Injector {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹系统授权引导（只会弹一次，之后跳系统设置）。
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 写入文本并粘贴到最前窗口；回调在主线程，`pasted` 表示是否真的发出了按键。
    static func paste(_ text: String, config: VoiceConfig, completion: ((Bool) -> Void)? = nil) {
        guard !text.isEmpty else {
            completion?(false)
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = config.restoreClipboard ? snapshot(of: pasteboard) : []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted else {
            Log.shared.error("缺少辅助功能权限，无法粘贴（文本已留在剪贴板）")
            completion?(false)
            return
        }

        let delay = DispatchTimeInterval.milliseconds(max(0, config.pasteDelayMs))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postCommandV()
            completion?(true)

            guard config.restoreClipboard, !saved.isEmpty else { return }
            let restoreDelay = DispatchTimeInterval.milliseconds(max(0, config.restoreDelayMs))
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
        }
    }

    /// 仅用于自检：报告能否合成按键。
    static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// 拷贝剪贴板内容，供粘贴后恢复。惰性数据（如图片流）可能无法完全还原，属已知取舍。
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            let copy = NSPasteboardItem()
            var hasContent = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    hasContent = true
                }
            }
            return hasContent ? copy : nil
        }
    }
}
