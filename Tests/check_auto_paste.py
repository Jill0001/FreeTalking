"""Exercise the production pasteText method with an isolated clipboard and delayed receiver."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
source = (root / 'Ramblr/TranscriptionManager.swift').read_text()
start = source.index('    func pasteText(_ text: String) {')
end = source.index('    // MARK: - Output Handling', start)
method = source[start:end]
stubs = r'''
import Foundation
func logInfo(_ text: String) {}
func logError(_ text: String) {}
func AXIsProcessTrusted() -> Bool { true }
final class NSPasteboardItem {
 var values: [NSPasteboard.PasteboardType: Data] = [:]
 var types: [NSPasteboard.PasteboardType] { Array(values.keys) }
 func data(forType type: NSPasteboard.PasteboardType) -> Data? { values[type] }
 func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) { values[type] = data }
}
final class NSPasteboard {
 enum PasteboardType { case string }
 static let general = NSPasteboard()
 var pasteboardItems: [NSPasteboardItem]? = []
 var changeCount = 0
 func clearContents() { pasteboardItems = []; changeCount += 1 }
 @discardableResult func setString(_ value: String, forType type: PasteboardType) -> Bool {
  let item = NSPasteboardItem(); item.setData(Data(value.utf8), forType: type)
  pasteboardItems = [item]; changeCount += 1; return true
 }
 func writeObjects(_ items: [NSPasteboardItem]) { pasteboardItems = items; changeCount += 1 }
 var text: String? { pasteboardItems?.first?.data(forType: .string).flatMap { String(data: $0, encoding: .utf8) } }
}
final class CGEventSource {
 enum State { case hidSystemState }
 init(stateID: State) {}
}
final class CGEvent {
 enum Flags { case maskCommand }
 enum Tap { case cghidEventTap }
 var flags = Flags.maskCommand
 let down: Bool
 static var received: String?
 init?(keyboardEventSource: CGEventSource, virtualKey: Int, keyDown: Bool) { down = keyDown }
 func post(tap: Tap) {
  if down {
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
    Self.received = NSPasteboard.general.text
   }
  }
 }
}
final class NSWorkspace {
 static let shared = NSWorkspace()
 struct Application { let bundleIdentifier: String? = "test.delayed-editor" }
 var frontmostApplication: Application? { Application() }
}
final class PasteHarness {
 func showAccessibilityAlert() {}
'''
checks = r'''
}
NSPasteboard.general.setString("old clipboard", forType: .string)
let harness = PasteHarness()
harness.pasteText("new transcription")
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
guard CGEvent.received == "new transcription" else {
 print("FAIL: delayed editor received \(CGEvent.received ?? "nil") instead of new transcription")
 exit(1)
}
print("PASS: delayed editor received the transcription; no real clipboard, keyboard or API used")
'''
out = root / 'tmp/paste-race'
out.mkdir(parents=True, exist_ok=True)
(out/'PasteChecks.swift').write_text(stubs+method+checks)
subprocess.run(['swiftc',str(out/'PasteChecks.swift'),'-o',str(out/'paste-checks')],check=True)
raise SystemExit(subprocess.run([str(out/'paste-checks')]).returncode)
