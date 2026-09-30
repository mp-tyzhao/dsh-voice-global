import AVFoundation

/// 麦克风采集：AVAudioEngine → 重采样为 16 kHz 单声道 PCM16 → 规范 WAV。
///
/// 输出格式必须与 DSH 语音栈的校验一致（16kHz / 单声道 / 16bit，44 字节头），
/// 这样同一份音频既能给本地 SenseVoice 用，也能塞回 DSH 的转写接口。
final class Recorder {
    enum Failure: Error, CustomStringConvertible {
        case permissionDenied
        case noInputDevice
        case converterUnavailable

        var description: String {
            switch self {
            case .permissionDenied: return "没有麦克风权限"
            case .noInputDevice: return "找不到可用的麦克风输入"
            case .converterUnavailable: return "音频格式转换器创建失败"
            }
        }
    }

    /// 最少样本数：低于 0.1 秒视为误触，不送识别。
    private static let minimumSamples = 1600

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var currentLevel: Float = 0

    private(set) var isRecording = false

    /// 当前输入电平（0…1），供 HUD 画波形。
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 首次使用时弹系统授权框。
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch permissionStatus {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        guard Recorder.permissionStatus == .authorized else { throw Failure.permissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInputDevice }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure.converterUnavailable }

        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        currentLevel = 0
        lock.unlock()

        self.engine = engine
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        Log.shared.info("开始录音 (\(Int(format.sampleRate))Hz/\(format.channelCount)ch → 16kHz)")
    }

    /// 结束录音并返回规范 WAV；样本太少时返回 nil。
    func stop() -> Data? {
        guard isRecording else { return nil }
        teardown()

        lock.lock()
        let samples = pcm
        pcm.removeAll(keepingCapacity: true)
        currentLevel = 0
        lock.unlock()

        guard samples.count >= Recorder.minimumSamples * 2 else {
            Log.shared.info("录音过短（\(samples.count / 32)ms），已丢弃")
            return nil
        }
        Log.shared.info("结束录音，时长 \(samples.count / 32)ms")
        return Recorder.wav(from: samples)
    }

    /// 放弃本次录音（Esc 取消）。
    func cancel() {
        guard isRecording else { return }
        teardown()
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        currentLevel = 0
        lock.unlock()
        Log.shared.info("已取消录音")
    }

    private func teardown() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        isRecording = false
    }

    /// 音频线程回调：重采样、量化、累计电平。这里不做任何 UI 与文件操作。
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else {
            if let conversionError { Log.shared.error("重采样失败：\(conversionError)") }
            return
        }

        let count = Int(output.frameLength)
        guard count > 0 else { return }

        var samples = [Int16](repeating: 0, count: count)
        var energy: Float = 0
        for index in 0..<count {
            let value = max(-1, min(1, channel[0][index]))
            samples[index] = Int16(value * 32767)
            energy += value * value
        }
        let rms = (energy / Float(count)).squareRoot()

        lock.lock()
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            pcm.append(UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self), count: count * 2)
        }
        currentLevel = min(1, rms * 14)
        lock.unlock()
    }

    /// 组装规范的 16kHz 单声道 PCM16 WAV。
    static func wav(from pcm: Data) -> Data {
        var header = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        let dataSize = UInt32(pcm.count)
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))            // PCM
        append(UInt16(1))            // 单声道
        append(UInt32(16000))        // 采样率
        append(UInt32(32000))        // 字节率
        append(UInt16(2))            // 块对齐
        append(UInt16(16))           // 位深
        header.append(contentsOf: Array("data".utf8))
        append(dataSize)

        var output = header
        output.append(pcm)
        return output
    }
}
