import Foundation
import AVFoundation
import AppKit

protocol AudioCapturing: AnyObject {
    func start(sessionID: UUID, selectedUID: String, previewAudio: ((AVAudioPCMBuffer) -> Void)?, levels: @escaping (Float) -> Void) throws
    func stop() -> URL?
}

// UI state belongs to the main queue. The capture object is accessed exclusively
// on audioQueue; a timeout never releases it while a system call is still running.
final class AudioManager: NSObject, ObservableObject {
    enum State { case idle, starting, recording, stopping, recovering }
    @Published private(set) var state: State = .idle
    @Published private(set) var audioLevels: [Float] = []
    var isRecording: Bool { state == .recording }
    var isStartingRecording: Bool { state == .starting }
    var isBusy: Bool { state != .idle }
    let microphones = MicrophoneManager()

    private let capture: AudioCapturing
    private let audioQueue = DispatchQueue(label: "com.jiamengzhao.freetalking.audio")
    private let operationTimeout: TimeInterval
    private var sessionID = UUID()
    private var deadline: DispatchWorkItem?
    private var startCompletion: ((Result<Void, Error>) -> Void)?
    private var stopCompletion: ((Result<URL?, Error>) -> Void)?

    init(capture: AudioCapturing = AudioCaptureEngine(), operationTimeout: TimeInterval = 10,
         requestPermission: Bool = true) {
        self.capture = capture
        self.operationTimeout = operationTimeout
        super.init()
        if requestPermission { requestMicrophoneAccess() }
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted { logInfo("AudioManager: Microphone access granted"); return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Allow FreeTalking to use your microphone in System Settings > Privacy & Security > Microphone."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "FreeTalking.Audio", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func setState(_ next: State) {
        dispatchPrecondition(condition: .onQueue(.main))
        state = next
        if next != .recording { audioLevels.removeAll() }
        // The discard shortcut remains available while initialization is pending.
        NotificationCenter.default.post(name: NSNotification.Name("RecordingStatusChanged"), object: nil,
                                        userInfo: ["isRecording": next == .recording || next == .starting])
    }

    private func armDeadline(operation: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .starting || self.state == .stopping else { return }
            logError("AudioManager [\(self.sessionID)]: \(operation) timed out; waiting for audio cleanup")
            self.setState(.recovering)
            let failure = self.error(5, "The microphone did not respond while \(operation). Audio is still recovering. If it does not recover, restart FreeTalking or reconnect the microphone.")
            let start = self.startCompletion; self.startCompletion = nil
            let stop = self.stopCompletion; self.stopCompletion = nil
            start?(.failure(failure))
            stop?(.failure(failure))
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + operationTimeout, execute: work)
    }

    func startRecording(previewAudio: ((AVAudioPCMBuffer) -> Void)? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .idle else {
            completion(.failure(error(6, "Audio is busy or recovering. Wait for it to finish before recording again.")))
            return
        }
        sessionID = UUID()
        let id = sessionID
        let selectedUID = microphones.selectedUID
        startCompletion = completion
        setState(.starting)
        armDeadline(operation: "starting recording")
        logInfo("AudioManager [\(id)]: Starting recording")
        audioQueue.async {
            let result: Result<Void, Error>
            do {
                try self.capture.start(sessionID: id, selectedUID: selectedUID, previewAudio: previewAudio) { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self, self.sessionID == id, self.state == .recording else { return }
                        if self.audioLevels.count >= 15 { self.audioLevels.removeFirst() }
                        self.audioLevels.append(level)
                    }
                }
                result = .success(())
            } catch {
                logError("AudioManager [\(id)]: Start failed: \(error)")
                if let url = self.capture.stop() { try? FileManager.default.removeItem(at: url) }
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.deadline?.cancel()
                if self.state == .starting {
                    let callback = self.startCompletion; self.startCompletion = nil
                    switch result {
                    case .success:
                        self.audioLevels = Array(repeating: 0.02, count: 10)
                        self.setState(.recording)
                    case .failure: self.setState(.idle)
                    }
                    callback?(result)
                } else {
                    // Cancellation/timeout already completed the UI request.
                    // A late successful engine must be stopped before another start.
                    self.audioQueue.async {
                        if case .success = result {
                            if let url = self.capture.stop() { try? FileManager.default.removeItem(at: url) }
                        }
                        DispatchQueue.main.async { self.setState(.idle) }
                    }
                }
            }
        }
    }

    func cancelStartingRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .starting else { return }
        deadline?.cancel()
        setState(.recovering)
        let callback = startCompletion; startCompletion = nil
        callback?(.failure(CancellationError()))
    }

    func stopRecording(discard: Bool = false, completion: @escaping (Result<URL?, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .recording else {
            completion(.failure(error(7, "There is no active recording to stop.")))
            return
        }
        setState(.stopping)
        stopCompletion = completion
        armDeadline(operation: "stopping recording")
        audioQueue.async {
            var url = self.capture.stop()
            if discard, let capturedURL = url {
                do { try FileManager.default.removeItem(at: capturedURL) }
                catch { logError("AudioManager: Failed to discard recording: \(error)") }
                url = nil
            }
            let savedURL = url
            DispatchQueue.main.async {
                self.deadline?.cancel()
                let callback = self.stopCompletion; self.stopCompletion = nil
                self.setState(.idle)
                callback?(.success(savedURL))
            }
        }
    }
}
