import Foundation
import AppKit
import CoreGraphics
import UserNotifications
enum APIKeyTestResult: Equatable {
    case valid
    case missingKey
    case invalidKey
    case accessDenied
    case modelUnavailable
    case rateLimited
    case serviceUnavailable
    case networkError
    case timedOut
    case invalidResponse

    var message: String {
        switch self {
        case .valid:
            return "Connected — this key can access the selected model."
        case .missingKey:
            return "Paste an API key first."
        case .invalidKey:
            return "This API key is invalid or has been revoked."
        case .accessDenied:
            return "This key cannot access the selected project or model."
        case .modelUnavailable:
            return "The selected model is unavailable to this project."
        case .rateLimited:
            return "The key was accepted, but the project is rate-limited or out of quota."
        case .serviceUnavailable:
            return "The API service is temporarily unavailable. Try again shortly."
        case .networkError:
            return "Couldn't reach the API. Check your internet connection."
        case .timedOut:
            return "The connection test timed out. Try again."
        case .invalidResponse:
            return "The API returned an unexpected response. Try again."
        }
    }

    var isSuccess: Bool {
        self == .valid
    }

    var isWarning: Bool {
        self == .rateLimited || self == .serviceUnavailable || self == .networkError || self == .timedOut
    }
}

class TranscriptionManager: ObservableObject {
    @Published var hasAccessibilityPermission = false
    @Published var statusMessage = ""
    @Published var history: [String] = []
    @Published private(set) var apiKey: String?
    // Save-to-folder configuration
    @Published var saveFolderPath: String?
    @Published var saveFolderEnabled: Bool = false
    @Published var saveSubdirectoryFormat: String = "{year}/{month}/{day}"
    private let saveFolderPathKey = "TranscriptionSaveFolderPath"
    private let saveFolderEnabledKey = "TranscriptionSaveFolderEnabled"
    private let saveSubdirectoryFormatKey = "TranscriptionSaveSubdirectoryFormat"

    init() {
        loadAPIKey()
        loadHistory()
        loadSaveFolderSettings()
        // Do not prompt on startup unless auto-paste is enabled
        let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
        if autoPasteEnabled {
            checkAccessibilityPermission(shouldPrompt: true)
        } else {
            // Update state silently without prompting
            checkAccessibilityPermission(shouldPrompt: false)
        }
    }
    
    private func loadAPIKey() {
        apiKey = UserDefaults.standard.string(forKey: "OpenAIAPIKey")
    }
    
    func setAPIKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: "OpenAIAPIKey")
    }

    func testAPIKey(key: String, completion: @escaping (APIKeyTestResult) -> Void) {
        let authKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        func finish(_ result: APIKeyTestResult) {
            DispatchQueue.main.async {
                completion(result)
            }
        }

        guard !authKey.isEmpty else {
            finish(.missingKey)
            return
        }

        let modelForAPI = LivePreview.modelID
        let url = URL(string: "https://api.openai.com/v1/models/")!.appendingPathComponent(modelForAPI)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        logInfo("Testing OpenAI API key access for model \(modelForAPI)")

        session.dataTask(with: request) { _, response, error in
            session.finishTasksAndInvalidate()

            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    logError("API key test timed out for model \(modelForAPI)")
                    finish(.timedOut)
                } else {
                    logError("API key test could not reach the provider for model \(modelForAPI)")
                    finish(.networkError)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                logError("API key test received a non-HTTP response for model \(modelForAPI)")
                finish(.invalidResponse)
                return
            }

            let statusCode = httpResponse.statusCode
            logInfo("API key test response for model \(modelForAPI): HTTP \(statusCode)")

            let result: APIKeyTestResult
            switch statusCode {
            case 200...299:
                result = .valid
            case 401:
                result = .invalidKey
            case 403:
                result = .accessDenied
            case 404:
                result = .modelUnavailable
            case 429:
                result = .rateLimited
            case 500...599:
                result = .serviceUnavailable
            default:
                result = .invalidResponse
            }
            finish(result)
        }.resume()
    }
    
    func checkAccessibilityPermission(shouldPrompt: Bool = false) {
        // Check if we have accessibility permission
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = trusted
            if !trusted && shouldPrompt {
                self.showAccessibilityAlert()
            }
        }
    }
    
    // New method that incorporates retries and handles file chunking
    func pasteText(_ text: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.pasteText(text) }
            return
        }
        logInfo("Starting text paste operation")
        
        // First check if we have accessibility permission
        if !AXIsProcessTrusted() {
            logError("No accessibility permission")
            DispatchQueue.main.async {
                self.showAccessibilityAlert()
            }
            return
        }
        
        let pasteboard = NSPasteboard.general

        // Put transcription text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V using CGEvent
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),   // 0x09 = kVK_ANSI_V
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logError("Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        logInfo("Sent Cmd+V to active application \(target); transcription retained on clipboard; insertion unverified")
        // Keyboard event delivery is asynchronous. Keep the payload available until
        // the user or another app replaces it, so slow editors can still read it.

    }

    // MARK: - Output Handling

    /// Routes the transcription output based on the user's preference.
    /// When AutoPaste is enabled (default), the text is typed into the active app.
    /// Otherwise, the text is copied to the clipboard and a notification is shown.
    func handleTranscriptionOutput(_ text: String, recordingURL: URL, clipboardOnly: Bool = false) {
        let isAutoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
        let savedURL = saveTranscriptionToFile(text)
        addToHistory(text, files: [recordingURL, savedURL].compactMap { $0?.path })
        if isAutoPasteEnabled && !clipboardOnly {
            // If auto-paste is on but we don't have permission, show prompt and fall back to copy
            if !AXIsProcessTrusted() {
                checkAccessibilityPermission(shouldPrompt: true)
                copyToClipboardAndNotify(text)
            } else {
                pasteText(text)
            }
        } else {
            copyToClipboardAndNotify(text)
        }
    }

    /// Copies the given text to the clipboard and posts a local notification to inform the user.
    private func copyToClipboardAndNotify(_ text: String) {
        logInfo("Copying transcription to clipboard")

        writeToClipboard(text)

        DispatchQueue.main.async {
            self.statusMessage = "Copied to clipboard"
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "Copied to clipboard"]
            )
        }

        requestNotificationAuthorizationIfNeeded { authorized in
            guard authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Transcription copied to clipboard"
            let preview = text.prefix(80)
            content.body = preview.isEmpty ? "Ready to paste." : "\(preview)…"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil // deliver immediately
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    logError("Failed to deliver notification: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Requests user notification permission only if needed, then calls completion with current authorization state.
    private func requestNotificationAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // For LSUIElement (agent) apps, the system may not show the permission prompt
                // unless the app is temporarily activated. Elevate policy briefly to ensure
                // the prompt appears, then restore the prior policy.
                DispatchQueue.main.async {
                    let previousPolicy = NSApp.activationPolicy()
                    let shouldElevate = previousPolicy != .regular
                    if shouldElevate {
                        _ = NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        DispatchQueue.main.async {
                            if shouldElevate {
                                _ = NSApp.setActivationPolicy(previousPolicy)
                            }
                            completion(granted)
                        }
                    }
                }
            case .authorized, .provisional:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    // MARK: - History

    private let historyKey = "TranscriptionHistory"
    private let historyLimit = 10

    private func loadHistory() {
        if let stored = UserDefaults.standard.array(forKey: historyKey) as? [String] {
            DispatchQueue.main.async {
                self.history = stored
            }
        }
    }

    private func persistHistory() {
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    @Published private(set) var historyFiles = UserDefaults.standard.dictionary(forKey: "HistoryFiles") as? [String: [String]] ?? [:]

    private func addToHistory(_ text: String, files: [String]) {
        DispatchQueue.main.async {
            // Remove existing duplicate if present, then insert at top
            if let existingIndex = self.history.firstIndex(of: text) {
                self.history.remove(at: existingIndex)
            }
            self.history.insert(text, at: 0)
            if self.history.count > self.historyLimit {
                self.history = Array(self.history.prefix(self.historyLimit))
            }
            self.historyFiles[text] = files
            self.historyFiles = self.historyFiles.filter { self.history.contains($0.key) }
            UserDefaults.standard.set(self.historyFiles, forKey: "HistoryFiles")
            self.persistHistory()
        }
    }

    private func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyFromHistory(_ text: String) {
        writeToClipboard(text)
    }

    func clearHistory() {
        DispatchQueue.main.async {
            self.history.removeAll()
            self.historyFiles.removeAll()
            UserDefaults.standard.removeObject(forKey: "HistoryFiles")
            UserDefaults.standard.removeObject(forKey: self.historyKey)
            self.statusMessage = "History cleared"
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "History cleared"]
            )
        }
    }
    
    // MARK: - Save to Folder

    private func loadSaveFolderSettings() {
        saveFolderPath = UserDefaults.standard.string(forKey: saveFolderPathKey)
        saveFolderEnabled = UserDefaults.standard.bool(forKey: saveFolderEnabledKey)
        saveSubdirectoryFormat = UserDefaults.standard.string(forKey: saveSubdirectoryFormatKey) ?? "{year}/{month}/{day}"
    }

    func setSaveFolderPath(_ path: String?) {
        saveFolderPath = path
        if let path = path {
            UserDefaults.standard.set(path, forKey: saveFolderPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: saveFolderPathKey)
        }
        logInfo("TranscriptionManager: Save folder path set to \(path ?? "nil")")
    }

    func setSaveFolderEnabled(_ enabled: Bool) {
        saveFolderEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: saveFolderEnabledKey)
        logInfo("TranscriptionManager: Save folder enabled set to \(enabled)")
    }

    func setSaveSubdirectoryFormat(_ format: String) {
        saveSubdirectoryFormat = format
        UserDefaults.standard.set(format, forKey: saveSubdirectoryFormatKey)
        logInfo("TranscriptionManager: Save subdirectory format set to \(format)")
    }

    private func saveTranscriptionToFile(_ text: String) -> URL? {
        guard saveFolderEnabled,
              let basePath = saveFolderPath,
              !basePath.isEmpty else { return nil }

        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)

        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        let hour = String(format: "%02d", components.hour ?? 0)
        let minute = String(format: "%02d", components.minute ?? 0)
        let second = String(format: "%02d", components.second ?? 0)

        let subdirectory = saveSubdirectoryFormat
            .replacingOccurrences(of: "{year}", with: year)
            .replacingOccurrences(of: "{month}", with: month)
            .replacingOccurrences(of: "{day}", with: day)
            .replacingOccurrences(of: "{hour}", with: hour)
            .replacingOccurrences(of: "{minute}", with: minute)

        let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
        let directoryURL = subdirectory.isEmpty ? baseURL : baseURL.appendingPathComponent(subdirectory, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logError("TranscriptionManager: Failed to create save directory: \(error)")
            return nil
        }

        let timestamp = "\(year)-\(month)-\(day)_\(hour)-\(minute)-\(second)"
        let slug = text.prefix(40)
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(5)
            .joined(separator: "-")
            .replacingOccurrences(of: "[^a-zA-Z0-9\\-]", with: "", options: .regularExpression)

        let filename = slug.isEmpty ? "\(timestamp).txt" : "\(timestamp)_\(slug).txt"
        let fileURL = directoryURL.appendingPathComponent(filename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            logError("TranscriptionManager: Failed to save transcription file: \(error)")
            return nil
        }
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Permission Required"
            alert.informativeText = "FreeTalking needs accessibility permission to simulate keyboard events. Please grant access in System Settings > Privacy & Security > Accessibility, then quit and relaunch FreeTalking."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
