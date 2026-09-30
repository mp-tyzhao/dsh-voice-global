// 单实例保护的回归测试
// ====================
//
// 跑法（在仓库根目录）：
//   swiftc -O -o /tmp/single-instance-test Sources/SingleInstance.swift tests/single-instance.test.swift \
//     && /tmp/single-instance-test
//
// 覆盖三件事：
//   1. 空场时能拿到锁
//   2. 别的进程持锁时拿不到锁（这正是"两份 App 并存"的场景）
//   3. 持锁进程退出后锁自动释放，不会把用户永久挡在门外（没有陈旧锁）
//
// 每个锁操作都放到独立子进程里做：flock 是按"打开文件描述"计的，同进程内两次
// open 拿到两个不同描述，测不出真实的跨进程行为。
// 锁文件路径必须由父进程算好传给子进程 —— 子进程 pid 不同，各自算就会锁到不同文件。

import AppKit
import Foundation

@main
struct SingleInstanceTest {
    /// 子进程用 argv[2] 传进来的路径；父进程按自己的 pid 生成
    static var lockPath: String {
        if CommandLine.arguments.count > 2 { return CommandLine.arguments[2] }
        return NSTemporaryDirectory() + "vg-single-instance-test-\(getpid()).lock"
    }

    /// 起一个子进程跑指定模式
    @discardableResult
    static func spawn(_ mode: String, wait: Bool) -> (process: Process, code: Int32) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [mode, lockPath]
        try? child.run()
        guard wait else { return (child, -1) }
        child.waitUntilExit()
        return (child, child.terminationStatus)
    }

    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "--hold":
            // 拿住锁不放，等父进程来杀
            guard SingleInstance.acquire(lockPath: lockPath) else { exit(3) }
            Thread.sleep(forTimeInterval: 10)
            exit(0)
        case "--try":
            // 能拿到锁就 0，拿不到就 1
            exit(SingleInstance.acquire(lockPath: lockPath) ? 0 : 1)
        default:
            break
        }

        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL")  \(label)")
            if !ok { failures += 1 }
        }

        // 0. 空场：应该能拿到
        check("空场时能取得锁", spawn("--try", wait: true).code == 0)

        // 1. 另一个进程持锁期间：应该拿不到
        let holder = spawn("--hold", wait: false).process
        Thread.sleep(forTimeInterval: 1.0)   // 等它真的把锁拿到
        check("别的进程持锁时拿不到（重复实例会被挡住）", spawn("--try", wait: true).code == 1)

        // 2. 持锁进程被杀之后：锁应该自动释放
        holder.terminate()
        holder.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
        check("持锁进程退出后锁自动释放（没有陈旧锁）", spawn("--try", wait: true).code == 0)

        try? FileManager.default.removeItem(atPath: lockPath)

        print()
        if failures == 0 {
            print("ALL PASS (3 项)")
            exit(0)
        }
        print("\(failures) 项失败")
        exit(1)
    }
}
