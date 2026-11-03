import Foundation
import AVFoundation

/// Full-duplex audio for live conversations: microphone → 16 kHz PCM chunks,
/// 24 kHz PCM from the model → speaker. Uses Apple's voice processing for
/// echo cancellation so JARVIS doesn't hear itself.
final class LiveAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let speakerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    private var chunk = Data()
    private var running = false

    /// 100 ms chunks of 16-bit little-endian mono PCM at the requested rate.
    var onMicrophoneChunk: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    /// Called when everything the model said has finished playing.
    var onPlaybackDrained: (() -> Void)?

    private var _muted = false
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingBuffers > 0
    }

    var isRunning: Bool { running }

    func start(micSampleRate: Double = 16_000) throws {
        if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: micSampleRate, channels: 1, interleaved: true) {
            micFormat = format
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "JARVIS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: micFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Microphone

    private func process(_ buffer: AVAudioPCMBuffer) {
        onInputLevel?(LiveAudioIO.rms(buffer))
        guard !muted, let converter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        chunk.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
        if chunk.count >= Int(micFormat.sampleRate * 0.1) * 2 {
            let ready = chunk
            chunk.removeAll(keepingCapacity: true)
            onMicrophoneChunk?(ready)
        }
    }

    // MARK: Speaker

    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard running, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for index in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                channel[index] = Float(sample) / 32_768
            }
        }
        onOutputLevel?(LiveAudioIO.rms(buffer))
        lock.lock()
        pendingBuffers += 1
        let generation = playbackGeneration
        lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard generation == self.playbackGeneration else { self.lock.unlock(); return }
            self.pendingBuffers = max(0, self.pendingBuffers - 1)
            let drained = self.pendingBuffers == 0
            self.lock.unlock()
            if drained { self.onPlaybackDrained?() }
        }
        if !player.isPlaying { player.play() }
    }

    /// Stops whatever the model was saying (user interrupted).
    func flushPlayback() {
        lock.lock()
        playbackGeneration += 1
        pendingBuffers = 0
        lock.unlock()
        player.stop()
        if running { player.play() }
        onOutputLevel?(0)
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for index in 0..<frames { sum += data[index] * data[index] }
        } else if let data = buffer.int16ChannelData?[0] {
            for index in 0..<frames {
                let value = Float(data[index]) / 32_768
                sum += value * value
            }
        }
        return min(1, sqrt(sum / Float(frames)) * 6)
    }
}
