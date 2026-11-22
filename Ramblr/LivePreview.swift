import AVFoundation
import Foundation

/// One WebSocket and one continuous resampler per recording. All mutable state lives on queue.
final class LivePreview {
    static let modelID = "gpt-live-transcribe"

    private let queue = DispatchQueue(label: "FreeTalking.live-preview")
    private let socket: URLSessionWebSocketTask
    private let update: (String) -> Void
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var ready = false
    private var sending = false
    private var completion: ((String?) -> Void)?
    private var committed = false
    private var closed = false
    private var transcript = ""

    init(key: String, prompt: String, update: @escaping (String) -> Void) {
        self.update = update
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        queue.async {
            var transcription: [String: Any] = ["model": Self.modelID, "delay": "low",
                                                  "languages": ["zh", "en"]]
            if !prompt.isEmpty { transcription["prompt"] = prompt }
            let input: [String: Any] = ["format": ["type": "audio/pcm", "rate": 24000],
                                        "transcription": transcription, "turn_detection": NSNull()]
            self.send(["type": "session.update", "session": ["type": "transcription",
                                                              "audio": ["input": input]]])
            self.receive()
        }
    }

    // RecordingSink supplies an owned, immutable copy of the microphone buffer.
    func append(_ audio: AVAudioPCMBuffer) {
        queue.async {
            guard !self.closed else { return }
            if self.converter == nil {
                self.converter = AVAudioConverter(from: audio.format, to: self.format)
            }
            let capacity = AVAudioFrameCount(ceil(Double(audio.frameLength) * 24000 / audio.format.sampleRate)) + 64
            guard let converter = self.converter,
                  let pcm = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: capacity)
            else { self.fail("audio format"); return }
            var supplied = false
            var error: NSError?
            converter.convert(to: pcm, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return audio
            }
            guard error == nil, let samples = pcm.int16ChannelData else { self.fail("audio conversion"); return }
            self.pending.append(Data(bytes: samples[0], count: Int(pcm.frameLength) * 2))
            if self.pending.count > 48000 * 12 { self.fail("connection stalled"); return }
            self.flush()
        }
    }

    private func flush() {
        guard ready, !sending, !closed, !committed else { return }
        if pending.isEmpty, completion != nil {
            committed = true
            send(["type": "input_audio_buffer.commit"])
            return
        }
        guard !pending.isEmpty, pending.count >= 4800 || completion != nil else { return }
        let audio = pending.base64EncodedString()
        pending.removeAll(keepingCapacity: true)
        sending = true
        send(["type": "input_audio_buffer.append", "audio": audio]) {
            self.sending = false
            self.flush()
        }
    }

    private func send(_ event: [String: Any], completion: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { fail("invalid event"); return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { error in
            self.queue.async {
                guard !self.closed else { return }
                if let error { self.fail(error.localizedDescription); return }
                completion?()
            }
        }
    }

    private func receive() {
        socket.receive { result in
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure(let error): self.fail(error.localizedDescription)
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: self.fail("unknown WebSocket message"); return
                    }
                    if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        switch event["type"] as? String {
                        case "session.updated", "transcription_session.updated":
                            self.ready = true
                            self.flush()
                        case "conversation.item.input_audio_transcription.delta":
                            self.transcript += event["delta"] as? String ?? ""
                            self.update(self.transcript)
                        case "conversation.item.input_audio_transcription.completed":
                            if self.committed {
                                let text = event["transcript"] as? String
                                self.close(result: text)
                            }
                        case "error", "conversation.item.input_audio_transcription.failed":
                            self.fail((event["error"] as? [String: Any])?["code"] as? String ?? "API error")
                        default: break
                        }
                    }
                    if !self.closed { self.receive() }
                }
            }
        }
    }

    private func fail(_ reason: String) {
        logError("Live preview unavailable: " + reason)
        update("Live preview unavailable · recording continues")
        close()
    }

    func finish(_ completion: @escaping (String?) -> Void) {
        queue.async {
            guard !self.closed else { completion(nil); return }
            self.completion = completion
            if let converter = self.converter,
               let tail = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: 4096) {
                var error: NSError?
                repeat {
                    tail.frameLength = 0
                    converter.convert(to: tail, error: &error) { _, status in
                        status.pointee = .endOfStream
                        return nil
                    }
                    guard error == nil else { self.fail("audio conversion"); return }
                    if let samples = tail.int16ChannelData {
                        self.pending.append(Data(bytes: samples[0], count: Int(tail.frameLength) * 2))
                    }
                } while tail.frameLength == tail.frameCapacity
            }
            self.flush()
            self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                if let self, !self.closed { self.fail("final transcript timed out") }
            }
        }
    }

    func stop() { queue.async { self.close() } }

    private func close(result: String? = nil) {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        let callback = completion
        completion = nil
        callback?(result)
        socket.cancel(with: .goingAway, reason: nil)
    }
}
