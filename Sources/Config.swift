import Foundation

/// 所有用户可见路径：配置、日志、模型、临时音频。
enum Paths {
    /// 用户主目录：优先用 $HOME（与安装脚本、Node 保持一致），
    /// 保证"脚本装到哪里、App 就读哪里"，也便于隔离测试。
    /// GUI 应用由 launchd 启动时 $HOME 就是真实主目录，行为不变。
    static let userHome: URL = {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// 数据目录。老版本用过 ~/.dsh-voice-global，首次启动时自动迁移。
    static let home: URL = {
        let fileManager = FileManager.default
        let current = userHome.appendingPathComponent(".voice-global", isDirectory: true)
        let legacy = userHome.appendingPathComponent(".dsh-voice-global", isDirectory: true)

        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
            do {
                try fileManager.moveItem(at: legacy, to: current)
            } catch {
                // 迁移失败也要能用：至少把配置带过来
                try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
                try? fileManager.copyItem(at: legacy.appendingPathComponent("config.json"),
                                          to: current.appendingPathComponent("config.json"))
            }
        }
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()

    static var config: URL { home.appendingPathComponent("config.json") }
    static var log: URL { home.appendingPathComponent("log.txt") }
    /// 密钥文件（0600）：`KEY=value` 形式，避免把密钥写进可分享的 config.json。
    static var envFile: URL { home.appendingPathComponent(".env") }
    static var models: URL { home.appendingPathComponent("models", isDirectory: true) }

    /// 应用包内资源目录。打包分发时把 Node 运行时与识别模型放进这里，
    /// 目标机器就不用自己装 Node、也不用首次下载 231MB 模型。
    /// 直接从源码编译来跑（未打包）时这些目录不存在，行为与以前完全一致。
    static var bundledResources: URL? { Bundle.main.resourceURL }

    /// 包内自带的 Node 可执行文件（由 scripts/package.sh 放入）。
    static var bundledNode: String? {
        guard let path = bundledResources?.appendingPathComponent("node/bin/node").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// 包内自带的识别模型根目录。
    static var bundledModelRoot: String? {
        guard let path = bundledResources?.appendingPathComponent("models").path,
              FileManager.default.fileExists(atPath: path + "/sensevoice-onnx/model.int8.onnx") else { return nil }
        return path
    }

    static var tmp: URL {
        let url = home.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct LLMConfig: Codable {
    /// 是否启用模型润色（cleanup = "llm" 时才真正调用）。
    var enabled = false
    /// OpenAI 兼容端点，例如 https://api.deepseek.com/v1
    var baseURL = ""
    /// 密钥；留空则依次尝试 apiKeyEnv 指向的环境变量、数据目录下的 .env、apiKeyCommand。
    var apiKey = ""
    /// 从哪个环境变量 / .env 键读密钥。GUI 应用不继承 shell 环境变量，所以 .env 是主路径。
    var apiKeyEnv = "DEEPSEEK_API_KEY"
    /// 形如 `security find-generic-password -s my-key -w`，在登录 shell 里执行以取得密钥。
    var apiKeyCommand = ""
    var model = ""
    var timeoutMs = 4500
}

struct VoiceConfig: Codable {
    /// 识别语言提示：auto / zh / en / yue / ja / ko
    var language = "auto"
    /// 清理强度：off（只转写）| rules（规则清理，默认）| llm（规则 + 模型润色）
    var cleanup = "rules"
    /// 判定"单击 Fn"与"按住 Fn 组合键"的时间阈值（秒）
    var tapMaxSeconds = 0.45
    /// node 可执行文件路径；留空自动探测
    var nodePath = ""
    /// SenseVoice 模型根目录；留空用 DSH 的缓存位置
    var modelRoot = ""
    /// 可选：直接指定 ONNX 权重文件（换精度 / 换自训练权重）
    var modelPath = ""
    /// 可选：直接指定 tokens.txt
    var tokensPath = ""
    /// 可选：直接指定 Silero VAD 模型
    var vadPath = ""
    var threads = 2
    /// 粘贴后恢复原剪贴板内容
    var restoreClipboard = true
    var pasteDelayMs = 90
    var restoreDelayMs = 650
    /// 屏幕底部悬浮状态条
    var showHUD = true
    /// 开始/结束提示音
    var playSounds = true
    /// 空闲多久后卸载识别模型（秒）。模型常驻约 900MB，重载只要 0.4 秒，所以默认 5 分钟就释放。
    var idleUnloadSeconds = 300

    /// 去掉整段末尾的标点。听写多是"半句话"，自动补上的句号反而要手动删。
    /// 只剥末尾，中间的断句标点全部保留。注意 `？` 也在剥离范围内。
    var trimEndPunctuation = true

    // MARK: - 开发模式（特别版）

    /// sidecar 源码目录（仓库根路径）。填了就不再用 app 包内的那份拷贝，
    /// 直接跑仓库里的 `sidecar/*.mjs` —— 改完不用重新打包 App。
    /// 留空 = 正常分发包行为。
    var devSidecarRoot = ""
    /// 盯住上面的目录，`.mjs` 一改就停掉识别进程，下次录音自动加载新代码。
    var devAutoReload = true

    // MARK: - 录音留存（特别版）

    /// 留存每段录音与转写元数据。**音频只留在本机，不上传。**
    /// 用途：改了 VAD 阈值 / 模型 / prompt 之后，拿同一批真实音频做回归对比。
    var keepRecordings = false
    /// 保留上限：条数 / 总大小 MB / 天数。0 表示该项不限制。
    var recordingsMaxCount = 500
    var recordingsMaxMB = 500
    var recordingsMaxDays = 30

    var llm = LLMConfig()

    /// 本机检测到的可用模型目录（包内自带的优先，其次自己下的，最后复用 DSH 已下载的缓存）。
    static var detectedModelRoot: String {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let bundled = Paths.bundledModelRoot { candidates.append(bundled) }
        candidates.append(Paths.models.path)
        candidates.append(Paths.userHome.appendingPathComponent(".dsh/speech-to-text/sensevoice/models").path)
        for candidate in candidates
        where fileManager.fileExists(atPath: candidate + "/sensevoice-onnx/model.int8.onnx") {
            return candidate
        }
        return Paths.models.path
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case language, cleanup, tapMaxSeconds, nodePath, modelRoot, threads
        case modelPath, tokensPath, vadPath
        case restoreClipboard, pasteDelayMs, restoreDelayMs, showHUD, playSounds, llm
        case idleUnloadSeconds, trimEndPunctuation
        case devSidecarRoot, devAutoReload
        case keepRecordings, recordingsMaxCount, recordingsMaxMB, recordingsMaxDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = c.fallback(.language, "auto")
        cleanup = c.fallback(.cleanup, "rules")
        tapMaxSeconds = c.fallback(.tapMaxSeconds, 0.45)
        nodePath = c.fallback(.nodePath, "")
        modelRoot = c.fallback(.modelRoot, "")
        modelPath = c.fallback(.modelPath, "")
        tokensPath = c.fallback(.tokensPath, "")
        vadPath = c.fallback(.vadPath, "")
        threads = c.fallback(.threads, 2)
        restoreClipboard = c.fallback(.restoreClipboard, true)
        pasteDelayMs = c.fallback(.pasteDelayMs, 90)
        restoreDelayMs = c.fallback(.restoreDelayMs, 650)
        showHUD = c.fallback(.showHUD, true)
        playSounds = c.fallback(.playSounds, true)
        idleUnloadSeconds = c.fallback(.idleUnloadSeconds, 300)
        trimEndPunctuation = c.fallback(.trimEndPunctuation, true)
        devSidecarRoot = c.fallback(.devSidecarRoot, "")
        devAutoReload = c.fallback(.devAutoReload, true)
        keepRecordings = c.fallback(.keepRecordings, false)
        recordingsMaxCount = c.fallback(.recordingsMaxCount, 500)
        recordingsMaxMB = c.fallback(.recordingsMaxMB, 500)
        recordingsMaxDays = c.fallback(.recordingsMaxDays, 30)
        llm = c.fallback(.llm, LLMConfig())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(language, forKey: .language)
        try c.encode(cleanup, forKey: .cleanup)
        try c.encode(tapMaxSeconds, forKey: .tapMaxSeconds)
        try c.encode(nodePath, forKey: .nodePath)
        try c.encode(modelRoot, forKey: .modelRoot)
        try c.encode(modelPath, forKey: .modelPath)
        try c.encode(tokensPath, forKey: .tokensPath)
        try c.encode(vadPath, forKey: .vadPath)
        try c.encode(threads, forKey: .threads)
        try c.encode(restoreClipboard, forKey: .restoreClipboard)
        try c.encode(pasteDelayMs, forKey: .pasteDelayMs)
        try c.encode(restoreDelayMs, forKey: .restoreDelayMs)
        try c.encode(showHUD, forKey: .showHUD)
        try c.encode(playSounds, forKey: .playSounds)
        try c.encode(idleUnloadSeconds, forKey: .idleUnloadSeconds)
        try c.encode(trimEndPunctuation, forKey: .trimEndPunctuation)
        try c.encode(devSidecarRoot, forKey: .devSidecarRoot)
        try c.encode(devAutoReload, forKey: .devAutoReload)
        try c.encode(keepRecordings, forKey: .keepRecordings)
        try c.encode(recordingsMaxCount, forKey: .recordingsMaxCount)
        try c.encode(recordingsMaxMB, forKey: .recordingsMaxMB)
        try c.encode(recordingsMaxDays, forKey: .recordingsMaxDays)
        try c.encode(llm, forKey: .llm)
    }

    /// 生效的模型根目录：显式配置 > 本机已有模型（自带目录或 DSH 缓存）> 自带目录（待 setup 下载）。
    var resolvedModelRoot: String {
        modelRoot.isEmpty ? VoiceConfig.detectedModelRoot : modelRoot
    }
}

extension LLMConfig {
    private enum CodingKeys: String, CodingKey {
        case enabled, baseURL, apiKey, apiKeyEnv, apiKeyCommand, model, timeoutMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.fallback(.enabled, false)
        baseURL = c.fallback(.baseURL, "")
        apiKey = c.fallback(.apiKey, "")
        apiKeyEnv = c.fallback(.apiKeyEnv, "DEEPSEEK_API_KEY")
        apiKeyCommand = c.fallback(.apiKeyCommand, "")
        model = c.fallback(.model, "")
        timeoutMs = c.fallback(.timeoutMs, 4500)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(apiKeyEnv, forKey: .apiKeyEnv)
        try c.encode(apiKeyCommand, forKey: .apiKeyCommand)
        try c.encode(model, forKey: .model)
        try c.encode(timeoutMs, forKey: .timeoutMs)
    }
}

extension KeyedDecodingContainer {
    /// 缺字段时使用默认值，避免用户只写一半配置就启动失败。
    func fallback<T: Decodable>(_ key: Key, _ defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key))?.flatMap { $0 } ?? defaultValue
    }
}

enum ConfigStore {
    /// 读取配置；文件不存在时写入一份带注释意义的默认配置。
    static func load() -> VoiceConfig {
        guard let data = try? Data(contentsOf: Paths.config) else {
            let config = VoiceConfig()
            save(config)
            return config
        }
        do {
            return try JSONDecoder().decode(VoiceConfig.self, from: data)
        } catch {
            Log.shared.error("配置解析失败，改用默认值：\(error)")
            return VoiceConfig()
        }
    }

    static func save(_ config: VoiceConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: Paths.config, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
        } catch {
            Log.shared.error("配置写入失败：\(error)")
        }
    }
}
