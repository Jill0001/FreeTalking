import Foundation
import AVFoundation

// All lifecycle methods run on AudioManager's serial audio queue.
final class AudioCaptureEngine: AudioCapturing {
    private var engine: AVAudioEngine?
    private var meter: AVAudioMixerNode?
    private var tapInstalled = false
    private var sink: RecordingSink?
    private var sessionID = UUID()

    private func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let started = ProcessInfo.processInfo.systemUptime
        logInfo("AudioCapture [\(sessionID)]: \(name) begin")
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            logInfo("AudioCapture [\(sessionID)]: \(name) end (\(String(format: "%.3f", elapsed))s)")
        }
        return try body()
    }

    func start(sessionID: UUID, selectedUID: String, previewAudio: ((AVAudioPCMBuffer) -> Void)?, levels: @escaping (Float) -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        self.sessionID = sessionID
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "FreeTalking.Audio", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Allow microphone access for FreeTalking in System Settings before recording."
            ])
        }
        let device = try stage("resolve device") { try MicrophoneManager.recordingDevice(selectedUID: selectedUID) }
        let engine = stage("create engine") { AVAudioEngine() }
        self.engine = engine
        let input = stage("get input node") { engine.inputNode }
        try stage("select device \(device.name) (\(device.deviceID))") {
            // Avoid reconfiguring an audio unit already bound to the desired input.
            if input.auAudioUnit.deviceID != device.deviceID {
                try input.auAudioUnit.setDeviceID(device.deviceID)
            }
            guard input.auAudioUnit.deviceID == device.deviceID else {
                throw NSError(domain: "FreeTalking.Audio", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Could not select the microphone. Choose another device in FreeTalking Settings."
                ])
            }
        }
        let format = stage("read input format") { input.inputFormat(forBus: 0) }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "FreeTalking.Audio", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The selected microphone has no available audio input. Reconnect it or choose another device."
            ])
        }
        let sink = try RecordingSink(format: format, previewAudio: previewAudio, levels: levels)
        self.sink = sink
        let meter = AVAudioMixerNode()
        self.meter = meter
        stage("connect input") {
            engine.attach(meter)
            engine.connect(input, to: meter, format: format)
        }
        stage("prepare engine") { engine.prepare() }
        stage("install tap") {
            meter.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                sink.append(buffer)
            }
            tapInstalled = true
        }
        try stage("start engine") { try engine.start() }
    }

    func stop() -> URL? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        stage("stop engine") { engine?.stop() }
        if tapInstalled {
            stage("remove tap") { meter?.removeTap(onBus: 0) }
            tapInstalled = false
        }
        let url = stage("drain buffers and close file") { sink?.finish() }
        stage("release engine") {
            meter = nil
            engine = nil
            sink = nil
        }
        return url
    }
}

// Each recording owns its buffers, converter and file. Queued callbacks from an
// old tap can never write into a later recording or publish its waveform.
final class RecordingSink {
    private let queue = DispatchQueue(label: "com.jiamengzhao.freetalking.samples")
    private let url: URL
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                             channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var closed = false
    private var framesWritten: AVAudioFramePosition = 0
    private var failed = false
    private let levels: (Float) -> Void

    private let previewAudio: ((AVAudioPCMBuffer) -> Void)?

    init(format: AVAudioFormat,
         url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("freetalking-\(UUID()).wav"),
         previewAudio: ((AVAudioPCMBuffer) -> Void)? = nil,
         levels: @escaping (Float) -> Void) throws {
        self.previewAudio = previewAudio
        self.levels = levels
        self.url = url
        converter = format == outputFormat ? nil : AVAudioConverter(from: format, to: outputFormat)
        guard format == outputFormat || converter != nil else {
            throw NSError(domain: "FreeTalking.Audio", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "The microphone's audio format could not be converted."
            ])
        }
        file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // The tap owns its buffer. Copy before asynchronously consuming samples.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, target) {
            if let from = src.mData, let to = dst.mData { memcpy(to, from, Int(src.mDataByteSize)) }
        }
        queue.async {
            guard !self.closed else { return }
            self.previewAudio?(copy)
            if let samples = copy.floatChannelData?[0], copy.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(copy.frameLength) { sum += samples[i] * samples[i] }
                let rms = sqrt(sum / Float(copy.frameLength))
                self.levels(rms > 0.002 ? min(1, rms * 30) : 0.02)
            }
            let output: AVAudioPCMBuffer
            if let converter = self.converter {
                let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16000 / copy.format.sampleRate)) + 32
                guard let converted = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return copy
                }
                if let error {
                    self.failed = true
                    logError("AudioCapture: Conversion failed: \(error)")
                    return
                }
                output = converted
            } else { output = copy }
            self.write(output)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        do {
            try file?.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            failed = true
            logError("AudioCapture: Writing audio failed: \(error)")
        }
    }

    func finish() -> URL? {
        // Only the background lifecycle queue waits for file writes, never main.
        queue.sync {
            guard !closed else { return framesWritten > 0 && !failed ? url : nil }
            closed = true
            // End-of-stream drains samples retained by the resampler.
            if let converter, !failed {
                while true {
                    let tail = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
                    var error: NSError?
                    let status = converter.convert(to: tail, error: &error) { _, inputStatus in
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    if let error {
                        failed = true
                        logError("AudioCapture: Final conversion failed: \(error)")
                        break
                    }
                    write(tail)
                    if status != .haveData || tail.frameLength == 0 || failed { break }
                }
            }
            file?.close()
            file = nil
            guard framesWritten > 0, !failed else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            logInfo("AudioCapture: Saved \(framesWritten) frames to \(url.lastPathComponent)")
            return url
        }
    }
}
