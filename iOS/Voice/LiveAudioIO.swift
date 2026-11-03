import Foundation
import AVFoundation

/// Full-duplex audio for live conversations: microphone → PCM chunks,
/// PCM from the model → speaker. Uses Apple's voice processing for echo
/// cancellation, and recovers automatically when iOS reconfigures audio
/// (starting the camera, plugging in headphones, a phone call…) – otherwise
/// the engine silently stops and the call goes quiet.
final class LiveAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let booster = AVAudioUnitEQ(numberOfBands: 0)
    private var converter: AVAudioConverter?
    private var micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let speakerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    private var chunk = Data()
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var attached = false

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

    /// Loudspeaker (true) or earpiece/headset (false).
    private(set) var speakerOn = true

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

        try? engine.inputNode.setVoiceProcessingEnabled(true)
        // Don't let voice processing turn down JARVIS's own voice.
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        booster.globalGain = 8
        if !attached {
            engine.attach(player)
            engine.attach(booster)
            attached = true
        }
        try wire()
        running = true
        applySpeaker()
        observe()
    }

    /// (Re)builds the graph: mic tap + player → booster → mixer.
    private func wire() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "JARVIS", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: micFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(booster)
        engine.connect(player, to: booster, format: speakerFormat)
        engine.connect(booster, to: engine.mainMixerNode, format: speakerFormat)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setSpeaker(_ on: Bool) {
        speakerOn = on
        applySpeaker()
    }

    private func applySpeaker() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType)
        let headphones: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .usbAudio]
        if outputs.contains(where: { headphones.contains($0) }) { return }
        try? session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }

    // MARK: Recovery

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.recover()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.recover()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.applySpeaker()
            if !self.engine.isRunning { self.recover() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recover()
        })
    }

    /// Restarts the engine after iOS stopped or reconfigured it.
    func recover() {
        guard running else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        if !engine.isRunning {
            engine.stop()
            try? wire()
        } else if !player.isPlaying {
            player.play()
        }
        applySpeaker()
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
        if !engine.isRunning { recover() }
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
