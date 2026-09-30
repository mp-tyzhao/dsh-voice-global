import AppKit
import Foundation

/// 单实例保护
/// ==========
///
/// 两份 App 同时运行时会各自安装 Fn 监听、各自粘贴一次 —— 用户看到的现象是
/// **"每说一句话就被录入两遍"**，而且很难自己想明白原因。
///
/// macOS 只在两份 App 的 bundle id 相同时用 `open` 去激活已有实例；如果两份来自
/// 不同路径（比如"下载"里解压了一份、"应用程序"里又放了一份），系统不会拦，
/// 两个进程会并存。
///
/// 这里用**文件锁**而不是"查同 bundle id 的进程"：直接 exec 启动的副本不一定
/// 注册到 LaunchServices；而 flock 在进程退出时由内核自动释放，不会留下陈旧锁
/// 把用户挡在门外。
enum SingleInstance {
    /// 持有锁期间必须一直保留这个 fd —— 进程退出时内核自动释放。
    private static var lockFD: Int32 = -1

    /// 尝试成为唯一实例。返回 false 表示已有别的实例在运行。
    static func acquire(lockPath: String) -> Bool {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        // 锁文件建不出来就不拦：宁可两个实例并存，也好过 App 直接起不来
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }
        close(fd)
        return false
    }

    /// 找出正在运行的另一个同类实例，用来告诉用户该关掉哪一个。
    static func otherInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }
    }
}
