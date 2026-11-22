import SwiftUI

struct SettingsView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var microphones: MicrophoneManager

    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var hotkeys: HotkeyManager
    @ObservedObject var media: MediaPlaybackManager
    @AppStorage("AutoPasteEnabled") private var autoPaste = false
    @State private var key = ""
    @State private var testMessage = ""
    @State private var testingKey: String?
    @AppStorage(TranscriptionContext.focusedTextKey) private var useFocusedContext = true

    var body: some View {
        TabView {
            dictation.tabItem { Label("Dictation", systemImage: "waveform") }
            output.tabItem { Label("Output", systemImage: "text.alignleft") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(12)
        .frame(width: 510, height: 535)
        .onAppear { microphones.refresh(); key = manager.apiKey ?? "" }
    }

    private var dictation: some View {
        Form {
            Section("OpenAI · Live dictation") {
                SecureField("API key", text: $key)
                    .onChange(of: key) { _, _ in testMessage = ""; testingKey = nil }
                HStack {
                    Button("Save Key") { manager.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(key == (manager.apiKey ?? ""))
                    Button("Test Connection") {
                        let draft = key
                        testingKey = draft
                        manager.testAPIKey(key: draft) { result in
                            guard testingKey == draft else { return }
                            testingKey = nil
                            testMessage = result.message
                        }
                    }.disabled(key.isEmpty || testingKey != nil)
                }
                if !testMessage.isEmpty { Text(testMessage).font(.caption) }
            }
            Section {
                Picker("Microphone", selection: $microphones.selectedUID) {
                    Text("System Default").tag("")
                    ForEach(microphones.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                    if microphones.selectedDeviceUnavailable {
                        Text("Selected microphone unavailable").tag(microphones.selectedUID)
                    }
                }
                .disabled(audioManager.isBusy)

                if microphones.selectedDeviceUnavailable {
                    Label("Reconnect your microphone or choose another device before recording.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if microphones.selectedUID.isEmpty {
                    Text("System input is \(microphones.defaultDeviceName)")
                        .foregroundStyle(.secondary)
                }

                Text(audioManager.isBusy
                     ? "The microphone can be changed when audio is idle."
                     : "Your selection is saved automatically and used for the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Audio Input", systemImage: "mic")
            }
            Section {
                Toggle("Use text near the cursor", isOn: $useFocusedContext)
                Text("Send up to 200 characters near the cursor to help recognize names and acronyms. Requires Accessibility access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            } header: {
                Label("Transcription Context", systemImage: "text.cursor")
            }
        }
        .formStyle(.grouped)
    }

    private var output: some View {
        Form {
            Section("After dictation") {
                Toggle("Auto-paste into active app", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, on in
                        if on { manager.checkAccessibilityPermission(shouldPrompt: true) }
                    }
                Toggle("Save transcripts as text files", isOn: Binding(
                    get: { manager.saveFolderEnabled }, set: manager.setSaveFolderEnabled))
                if manager.saveFolderEnabled {
                    LabeledContent("Folder") {
                        Button(manager.saveFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose Folder…") {
                            SaveFolderPanel.shared.show(folderPath: manager.saveFolderPath ?? "",
                                                        subdirectoryFormat: manager.saveSubdirectoryFormat) { path, format in
                                manager.setSaveFolderPath(path.isEmpty ? nil : path)
                                manager.setSaveSubdirectoryFormat(format)
                            }
                        }
                    }
                }
            }
            Section("During dictation") {
                Toggle("Pause media while recording", isOn: $media.isEnabled)
                    .onChange(of: media.isEnabled) { _, on in
                        if on { manager.checkAccessibilityPermission(shouldPrompt: true) }
                    }
                if media.isEnabled, let error = media.availabilityError { Text(error).font(.caption) }
            }
            Section {
                Button("Clear Recent Dictations") { manager.clearHistory() }.disabled(manager.history.isEmpty)
                Button("View Logs") { Logger.shared.openLogFile() }
                Button("Quit FreeTalking") { NSApp.terminate(nil) }
            }
        }.formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section("Recording shortcuts") {
                ShortcutSetting(title: "Start or finish", shortcut: hotkeys.displayString, save: hotkeys.updateHotkey)
                ShortcutSetting(title: "Discard", shortcut: hotkeys.cancelDisplayString, save: hotkeys.updateCancelHotkey)
                ShortcutSetting(title: "Clipboard only", shortcut: hotkeys.clipboardDisplayString, save: hotkeys.updateClipboardHotkey)
            }
        }.formStyle(.grouped)
    }
}
