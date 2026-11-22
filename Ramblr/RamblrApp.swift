import SwiftUI
import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger.shared
    let audioManager = AudioManager()
    let hotkeyManager = HotkeyManager()
    let transcriptionManager = TranscriptionManager()
    let mediaPlaybackManager = MediaPlaybackManager()
    private lazy var coordinator = RecordingCoordinator(
        audioManager: audioManager,
        transcriptionManager: transcriptionManager,
        mediaPlaybackManager: mediaPlaybackManager
    )
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("Application did finish launching")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        logInfo("System: \(osVersion), App Version: \(appVersion)")

        // Just ensure we're not active
        if NSApp.isActive {
            NSApp.deactivate()
        }
        // Ensure notifications show while app is active/agent
        UNUserNotificationCenter.current().delegate = self
        _ = coordinator
        statusItemController = StatusItemController(transcriptionManager: transcriptionManager)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        logInfo("Application will terminate")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logInfo("Application reopen requested; showing control panel")
        statusItemController?.showPanel()
        return true
    }

    // Show alert/banner even if app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct FreeTalkingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(audioManager: appDelegate.audioManager,
                         microphones: appDelegate.audioManager.microphones,
                         manager: appDelegate.transcriptionManager, hotkeys: appDelegate.hotkeyManager,
                         media: appDelegate.mediaPlaybackManager)
        }
    }
}
