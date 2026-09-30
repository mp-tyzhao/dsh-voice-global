import Foundation

/// 管理常驻转写进程（Node sidecar）。
///
/// 进程只在启动时加载一次 SenseVoice 模型，之后每段录音都只是"写路径 → 读结果"，
/// 因此说完到出字只有几十到几百毫秒。
final class Sidecar {
    enum Failure: Error, CustomStringConvertible {
        case nodeNotFound
        case scriptNotFound
        case notReady
        case processExited(String)

        var description: String {
            switch self {
            case .nodeNotFound: return "找不到 node 可执行文件，请在配置里填写 nodePath"
            case .scriptNotFound: return "找不到 sidecar/server.mjs"
            case .notReady: return "识别服务尚未就绪"
            case .processExited(let detail): return "识别进程已退出：\(detail)"
            }
        }
    }

    struct Result {
        let raw: String
        let text: String
        let hits: [String]
        let asrMilliseconds: Int
        let totalMilliseconds: Int
    }

    private let queue = DispatchQueue(label: "ai.dsh.voice-global.sidecar")
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [Int: (Swift.Result<Result, Error>) -> Void] = [:]
    private var nextId = 1
    private var ready = false
    private var readyWaiters: [(Swift.Result<Void, Error>) -> Void] = []
    private var fatalError: Error?
    /// 我们自己发起的退出（空闲卸载）不应报错。
    private var intentionalStop = false

    var isReady: Bool {
        queue.sync { ready }
    }

    /// 启动进程并等待模型加载完成。已在运行且就绪时直接成功，可安全重复调用。
    func start(config: VoiceConfig, completion: @escaping (Swift.Result<Void, Error>) -> Void) {
        lastConfig = config
        queue.async { [self] in
            if process != nil {
                if ready {
                    deliver(completion, .success(()))
                } else if let fatalError {
                    deliver(completion, .failure(fatalError))
                } else {
                    // 正在预热：排队等 ready
                    readyWaiters.append(completion)
                }
                return
            }
            do {
                let node = try resolveNode(config: config)
                let script = try resolveScript(config: config)
                self.ensureDevWatcher(config: config)
                let modelRoot = config.resolvedModelRoot

                let process = Process()
                process.executableURL = URL(fileURLWithPath: node)
                process.arguments = [script.path]
                var environment = ProcessInfo.processInfo.environment
                environment["VOICE_GLOBAL_MODEL_ROOT"] = modelRoot
                environment["VOICE_GLOBAL_THREADS"] = String(config.threads)
                environment["VOICE_GLOBAL_TRIM_END_PUNCT"] = config.trimEndPunctuation ? "1" : "0"
                // 允许直接指定单个文件，便于换精度（int8/fp32）或换一套自训练权重
                if !config.modelPath.isEmpty { environment["VOICE_GLOBAL_MODEL"] = config.modelPath }
                if !config.tokensPath.isEmpty { environment["VOICE_GLOBAL_TOKENS"] = config.tokensPath }
                if !config.vadPath.isEmpty { environment["VOICE_GLOBAL_VAD"] = config.vadPath }
                if config.llm.enabled, !config.llm.baseURL.isEmpty, !config.llm.model.isEmpty {
                    environment["VOICE_GLOBAL_LLM_BASE"] = config.llm.baseURL
                    environment["VOICE_GLOBAL_LLM_MODEL"] = config.llm.model
                    environment["VOICE_GLOBAL_LLM_TIMEOUT_MS"] = String(config.llm.timeoutMs)
                    if let key = resolveAPIKey(config: config) {
                        environment["VOICE_GLOBAL_LLM_KEY"] = key
                    }
                }
                process.environment = environment

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    self?.queue.async { self?.ingest(data) }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    text.split(separator: "\n").forEach { Log.shared.info("sidecar: \($0)") }
                }
                process.terminationHandler = { [weak self] proc in
                    self?.queue.async {
                        guard let self else { return }
                        let detail = "exit=\(proc.terminationStatus)"
                        if self.intentionalStop {
                            // 空闲卸载：正常回收，不当作故障
                            self.intentionalStop = false
                            self.ready = false
                            Log.shared.info("识别进程已按需退出（释放模型内存）")
                            return
                        }
                        Log.shared.error("识别进程退出：\(detail)")
                        self.failAll(Failure.processExited(detail))
                    }
                }

                try process.run()
                self.process = process
                self.stdin = inputPipe.fileHandleForWriting
                Log.shared.info("识别进程已启动：\(node) \(script.path)")

                // 等待 ready 事件（模型加载 0.4s 左右，冷启动可能更久）
                if self.ready {
                    deliver(completion, .success(()))
                } else {
                    self.readyWaiters.append(completion)
                }
            } catch {
                deliver(completion, .failure(error))
            }
        }
    }

    /// 提交一段 WAV 并取回清理后的文本。回调在主线程。
    func transcribe(wav: URL, config: VoiceConfig, completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        queue.async { [self] in
            guard let stdin, process != nil else {
                deliver(completion, .failure(fatalError ?? Failure.notReady))
                return
            }
            guard ready else {
                waitForReady { outcome in
                    switch outcome {
                    case .failure(let error): self.deliver(completion, .failure(error))
                    case .success: self.transcribe(wav: wav, config: config, completion: completion)
                    }
                }
                return
            }

            let id = nextId
            nextId += 1
            pending[id] = { result in
                switch result {
                case .success(let value):
                    self.deliver(completion, .success(value))
                case .failure(let error):
                    self.deliver(completion, .failure(error))
                }
            }
            let request: [String: Any] = [
                "id": id,
                "wav": wav.path,
                "language": config.language,
                "cleanup": config.llm.enabled ? config.cleanup : (config.cleanup == "llm" ? "rules" : config.cleanup),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  var line = String(data: data, encoding: .utf8) else {
                pending[id] = nil
                deliver(completion, .failure(Failure.notReady))
                return
            }
            line += "\n"
            do {
                try stdin.write(contentsOf: Data(line.utf8))
            } catch {
                pending[id] = nil
                deliver(completion, .failure(error))
            }
        }
    }

    func stop() {
        queue.sync {
            intentionalStop = process != nil
            stdin?.closeFile()
            stdin = nil
            process?.terminate()
            process = nil
            ready = false
            pending.removeAll()
        }
    }

    // MARK: - 内部

    /// 解析 stdout 的逐行 JSON。
    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.shared.info("sidecar 输出：\(line)")
            return
        }

        if let event = payload["event"] as? String {
            if event == "ready" {
                ready = true
                fatalError = nil
                Log.shared.info("识别服务就绪（模型加载 \(payload["loadMs"] ?? "?")ms，LLM=\(payload["llm"] ?? false)）")
                let waiters = readyWaiters
                readyWaiters.removeAll()
                waiters.forEach { deliver($0, .success(())) }
            } else if event == "fatal" {
                failAll(Failure.processExited(payload["error"] as? String ?? "未知错误"))
            }
            return
        }

        guard let id = payload["id"] as? Int else { return }
        let completion = pending.removeValue(forKey: id)
        guard let completion else { return }

        if payload["ok"] as? Bool == true {
            let result = Result(
                raw: payload["raw"] as? String ?? "",
                text: payload["text"] as? String ?? "",
                hits: payload["hits"] as? [String] ?? [],
                asrMilliseconds: (payload["timings"] as? [String: Any])?["asr"] as? Int ?? 0,
                totalMilliseconds: ((payload["timings"] as? [String: Any])?["asr"] as? Int ?? 0)
                    + ((payload["timings"] as? [String: Any])?["cleanup"] as? Int ?? 0)
                    + ((payload["timings"] as? [String: Any])?["llm"] as? Int ?? 0)
            )
            completion(.success(result))
        } else {
            completion(.failure(Failure.processExited(payload["error"] as? String ?? "转写失败")))
        }
    }

    private func waitForReady(_ completion: @escaping (Swift.Result<Void, Error>) -> Void) {
        if ready { deliver(completion, .success(())); return }
        if let fatalError { deliver(completion, .failure(fatalError)); return }
        readyWaiters.append(completion)
    }

    private func failAll(_ error: Error) {
        ready = false
        fatalError = error
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { deliver($0, .failure(error)) }
        let completions = pending.values
        pending.removeAll()
        completions.forEach { deliver($0, .failure(error)) }
    }

    /// 回调统一投递到主线程，避免调用方处理线程问题。
    private func deliver<T>(_ completion: @escaping (Swift.Result<T, Error>) -> Void, _ result: Swift.Result<T, Error>) {
        DispatchQueue.main.async { completion(result) }
    }

    /// 找 node：配置优先，其次应用包内自带的运行时，再次常见安装位置，最后问一次登录 shell。
    private func resolveNode(config: VoiceConfig) throws -> String {
        let fileManager = FileManager.default
        if !config.nodePath.isEmpty, fileManager.isExecutableFile(atPath: config.nodePath) {
            return config.nodePath
        }

        // 打包分发版自带 Node（scripts/package.sh 放入），有它就不依赖用户装过 Node
        if let bundled = Paths.bundledNode {
            return bundled
        }

        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        let nvmRoot = Paths.userHome.appendingPathComponent(".nvm/versions/node").path
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = versions.sorted { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedDescending
            }
            candidates.append(contentsOf: sorted.map { "\(nvmRoot)/\($0)/bin/node" })
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // GUI 应用不继承 shell 的 PATH，兜底问一次登录 shell
        if let shellPath = runLoginShell("command -v node"), !shellPath.isEmpty,
           fileManager.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        throw Failure.nodeNotFound
    }

    private func runLoginShell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    /// 解析 LLM 密钥，优先级：内联字段 → 环境变量 → 数据目录 .env → 自定义命令。
    /// GUI 应用不继承 shell 环境变量，所以 ~/.voice-global/.env 才是常规路径；
    /// 密钥只进内存，绝不写日志。
    private func resolveAPIKey(config: VoiceConfig) -> String? {
        if !config.llm.apiKey.isEmpty { return config.llm.apiKey }

        let name = config.llm.apiKeyEnv
        if !name.isEmpty {
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
                return value
            }
            if let value = readEnvFile(named: name) {
                return value
            }
        }

        guard !config.llm.apiKeyCommand.isEmpty else {
            Log.shared.error("没有找到 API 密钥（可写入 ~/.voice-global/.env 的 \(name)，或在 config.json 里填 llm.apiKey）")
            return nil
        }
        let value = runLoginShell(config.llm.apiKeyCommand)
        if value == nil { Log.shared.error("apiKeyCommand 没有输出，LLM 润色将不可用") }
        return value
    }

    /// 读取 ~/.voice-global/.env 里的 KEY=value（支持引号与 export 前缀）。
    private func readEnvFile(named name: String) -> String? {
        guard let content = try? String(contentsOf: Paths.envFile, encoding: .utf8) else { return nil }
        for rawLine in content.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix("\(name)=") else { continue }
            var value = String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// sidecar 脚本：开发模式指定目录优先，其次 app bundle 内的拷贝，最后回退源码目录。
    private func resolveScript(config: VoiceConfig) throws -> URL {
        // 【特别版】直接跑仓库里的 sidecar，改完 .mjs 不用重新打包 App
        if !config.devSidecarRoot.isEmpty {
            let dev = URL(fileURLWithPath: config.devSidecarRoot)
                .appendingPathComponent("sidecar/server.mjs")
            if FileManager.default.fileExists(atPath: dev.path) { return dev }
            Log.shared.info("开发模式：\(config.devSidecarRoot) 下没有 sidecar/server.mjs，回退到包内拷贝")
        }
        if let resource = Bundle.main.resourceURL {
            let bundled = resource.appendingPathComponent("sidecar/server.mjs")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sidecar/server.mjs")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        throw Failure.scriptNotFound
    }

    // MARK: - 开发模式：源码改动自动重载

    /// 最近一次 start(config:) 的配置，热重载重启时复用
    private var lastConfig: VoiceConfig?
    private var devWatchTimer: DispatchSourceTimer?
    private var devWatchBaseline: [String: Date]?

    /// 盯住仓库里的 sidecar 源码。任何一个 `.mjs` 变了就停掉进程，
    /// 下次录音会自动用新代码重新拉起 —— 不需要退出 App，也不需要重新打包。
    private func ensureDevWatcher(config: VoiceConfig) {
        guard config.devAutoReload, !config.devSidecarRoot.isEmpty, devWatchTimer == nil else { return }
        let dir = URL(fileURLWithPath: config.devSidecarRoot).appendingPathComponent("sidecar").path

        func snapshot() -> [String: Date] {
            var out: [String: Date] = [:]
            for name in ["server.mjs", "cleanup.mjs", "llm.mjs"] {
                let path = "\(dir)/\(name)"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let modified = attrs[.modificationDate] as? Date {
                    out[path] = modified
                }
            }
            return out
        }

        devWatchBaseline = snapshot()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.dsh.voice-global.devsync"))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = snapshot()
            guard let baseline = self.devWatchBaseline else { return }
            guard now != baseline else { return }
            self.devWatchBaseline = now
            let changed = now.filter { baseline[$0.key] != $0.value }.keys
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            Log.shared.info("检测到 sidecar 源码改动（\(changed.joined(separator: ", "))），重启识别进程以加载新代码")
            // 立刻重启而不是等下次录音：.mjs 改出语法错误时马上就能从日志看到，
            // 不用等到下一次听写才发现。stop()/start() 内部都用 queue.sync，
            // 必须切回主线程调用，否则死锁。
            DispatchQueue.main.async { [weak self] in
                guard let self, let config = self.lastConfig else { return }
                self.stop()
                self.start(config: config) { result in
                    switch result {
                    case .success:
                        Log.shared.info("热重载完成，识别服务已用新代码就绪")
                    case .failure(let error):
                        Log.shared.error("热重载失败（检查 sidecar/*.mjs）：\(error)")
                    }
                }
            }
        }
        devWatchTimer = timer
        timer.resume()
        Log.shared.info("开发模式：已盯住 \(dir)，改动 .mjs 会自动重载")
    }
}
