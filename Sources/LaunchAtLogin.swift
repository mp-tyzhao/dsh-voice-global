import Foundation
import ServiceManagement

/// 开机自启
/// ========
///
/// 菜单栏应用必须能开机自启 —— 用户重启电脑之后不会记得手动去开它，
/// 结果就是"语音输入莫名其妙不能用了"。
///
/// 用 macOS 13+ 的 `SMAppService.mainApp`：它把当前 App 注册成登录项，
/// 在「系统设置 → 通用 → 登录项」里可见、用户也能自己关掉。
/// 不写 LaunchAgent plist —— 那种方式不透明，用户找不到、也删不干净。
enum LaunchAtLogin {
    /// 当前是否已注册为登录项。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 系统里的状态原文，用于诊断。
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .notRegistered: return "未注册"
        case .notFound: return "系统找不到这个 App（可能被移动过）"
        case .requiresApproval: return "等待你在「系统设置 → 登录项」里允许"
        @unknown default: return "未知状态"
        }
    }

    /// 按配置开关注册或取消注册。
    ///
    /// 幂等：已经是对的状态就什么都不做，避免每次启动都写一次系统设置。
    /// 失败不抛给调用方 —— 自启失败不该拦着 App 启动，但必须记日志，
    /// 否则用户重启后才发现"又没起来"，而日志里什么都没有。
    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        let current = service.status

        if enabled {
            guard current != .enabled else { return true }
            do {
                try service.register()
                Log.shared.info("开机自启已开启（状态：\(statusDescription)）")
                return true
            } catch {
                Log.shared.error("开启开机自启失败：\(error)。可在「系统设置 → 通用 → 登录项」手动添加")
                return false
            }
        } else {
            guard current == .enabled || current == .requiresApproval else { return true }
            do {
                try service.unregister()
                Log.shared.info("开机自启已关闭")
                return true
            } catch {
                Log.shared.error("关闭开机自启失败：\(error)")
                return false
            }
        }
    }
}
