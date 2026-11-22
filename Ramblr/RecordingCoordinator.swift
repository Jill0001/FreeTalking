import AVFoundation
import SwiftUI
import Combine
import AppKit

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var mediaPlaybackManager: MediaPlaybackManager
    private var notificationObserver: NSObjectProtocol?
    private var isPreparingRecording = false
    private var preparationCancelled = false
    private var livePreview: LivePreview?
    private var previewID: UUID?
    private var recordingLimitTimer: Timer?
    private let maximumRecordingDuration: TimeInterval = 3 * 60
    private var cancellables = Set<AnyCancellable>()


    init(audioManager: AudioManager, transcriptionManager: TranscriptionManager, mediaPlaybackManager: MediaPlaybackManager) {
        logInfo("RecordingCoordinator: Initializing")
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager
        self.mediaPlaybackManager = mediaPlaybackManager

        // Observe audio levels for waveform indicator
        self.audioManager.$audioLevels.sink { levels in
            WaveformIndicatorWindow.shared.updateAudioLevels(levels)
        }.store(in: &cancellables)
        
        // Store the observer so it doesn't get deallocated
        self.notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received hotkey notification")
            self?.toggleRecording()
        }
        // Observe cancel hotkey
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CancelHotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received cancel hotkey notification")
            self?.cancelRecording()
        }
        // Observe clipboard hotkey (record without auto-paste)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClipboardHotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received clipboard hotkey notification")
            self?.toggleRecording(clipboardOnly: true)
        }
    }
    
    private func stopPreview() {
        previewID = nil
        livePreview?.stop()
        livePreview = nil
    }

    func cancelRecording() {
        guard isPreparingRecording || audioManager.isRecording else { return }
        stopPreview()
        if isPreparingRecording {
            preparationCancelled = true
            audioManager.cancelStartingRecording()
            WaveformIndicatorWindow.shared.hide()
            return
        }
        guard audioManager.isRecording else { return }
        clearRecordingLimit()
        mediaPlaybackManager.resumeIfWePaused()
        WaveformIndicatorWindow.shared.hide()
        audioManager.stopRecording(discard: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.transcriptionManager.statusMessage = "Recording discarded"
                NotificationCenter.default.post(name: NSNotification.Name("TranscriptionStatusChanged"),
                                                object: nil, userInfo: ["status": "Recording discarded"])
            case .failure(let error): self.showRecordingError(message: error.localizedDescription)
            }
        }
    }

    private func toggleRecording(clipboardOnly: Bool = false) {
        guard !isPreparingRecording else { return }
        if audioManager.isRecording {
            clearRecordingLimit()
            mediaPlaybackManager.resumeIfWePaused()
            audioManager.stopRecording { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let url):
                    guard let url else {
                        self.stopPreview()
                        WaveformIndicatorWindow.shared.hide()
                        self.showRecordingError(message: "No audio was received from the microphone. Check the input device and try again.")
                        return
                    }
                    WaveformIndicatorWindow.shared.showTranscribing(keepingPreview: true)
                    if let preview = self.livePreview {
                        self.finishLiveRecording(preview, url: url)
                    }
                case .failure(let error):
                    self.stopPreview()
                    WaveformIndicatorWindow.shared.hide()
                    self.showRecordingError(message: error.localizedDescription)
                }
            }
            return
        }
        guard !audioManager.isBusy, livePreview == nil else { return }
        guard let key = transcriptionManager.apiKey, !key.isEmpty else {
            showRecordingError(message: "Enter your OpenAI API key in FreeTalking Settings to start dictation.")
            return
        }
        let context = TranscriptionContext.capture()
        isPreparingRecording = true
        preparationCancelled = false
        mediaPlaybackManager.pauseIfPlaying { [weak self] in
            guard let self else { return }
            if self.preparationCancelled {
                self.isPreparingRecording = false
                self.mediaPlaybackManager.resumeIfWePaused()
                return
            }
            let indicator = WaveformIndicatorWindow.shared
            let id = UUID()
            self.previewID = id
            indicator.previewText = "Listening…"
            let preview = LivePreview(key: key, prompt: context.prompt) { [weak self] text in
                DispatchQueue.main.async {
                    guard self?.previewID == id else { return }
                    indicator.previewText = text
                }
            }
            self.livePreview = preview
            self.audioManager.startRecording(previewAudio: preview.append) { result in
                self.isPreparingRecording = false
                switch result {
                case .success:
                    self.startRecordingLimit()
                    let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
                    WaveformIndicatorWindow.shared.showWaveform(clipboardOnly: clipboardOnly,
                                                                 showOutputMode: autoPasteEnabled)
                case .failure(let error):
                    self.stopPreview()
                    self.clearRecordingLimit()
                    self.mediaPlaybackManager.resumeIfWePaused()
                    if !(error is CancellationError) { self.showRecordingError(message: error.localizedDescription) }
                }
            }
        }
    }

    private func finishLiveRecording(_ preview: LivePreview, url: URL) {
        let indicator = WaveformIndicatorWindow.shared
        preview.finish { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.livePreview === preview else { return }
                self.previewID = nil
                guard let text = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.livePreview = nil
                    indicator.hide()
                    self.showLiveError(recordingURL: url)
                    return
                }
                indicator.previewText = text
                self.transcriptionManager.handleTranscriptionOutput(text, recordingURL: url, clipboardOnly: indicator.clipboardOnly)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    indicator.hide()
                    self.livePreview = nil
                }
            }
        }
    }

    private func startRecordingLimit() {
        clearRecordingLimit()
        let timer = Timer(timeInterval: maximumRecordingDuration, repeats: false) { [weak self] timer in
            guard let self = self, self.recordingLimitTimer === timer else { return }
            self.clearRecordingLimit()
            // A delayed callback must never start a new recording.
            guard self.audioManager.isRecording else { return }
            logInfo("RecordingCoordinator: Reached 3-minute recording limit; stopping and transcribing")
            self.toggleRecording()
        }
        recordingLimitTimer = timer
        // Keep the deadline active while a menu is open or the user is dragging.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func clearRecordingLimit() {
        recordingLimitTimer?.invalidate()
        recordingLimitTimer = nil
    }

    private func showRecordingError(message: String = "Failed to capture audio recording. Please try again.") {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func showLiveError(recordingURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Live dictation could not finish"
        alert.informativeText = "Your microphone recording is available in Finder."
        alert.addButton(withTitle: "Show Recording")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
        }
    }

    deinit {
        recordingLimitTimer?.invalidate()
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
} 
