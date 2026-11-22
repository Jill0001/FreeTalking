import SwiftUI

struct ShortcutSetting: View {
    let title: String
    let shortcut: String
    let save: (UInt32, UInt32) -> Void
    @State private var editing = false

    var body: some View {
        LabeledContent(title) {
            Button(shortcut) { editing = true }
                .popover(isPresented: $editing) {
                    VStack {
                        Text("Press a new shortcut")
                        KeyCaptureRepresentable(onCaptured: { key, flags in
                            save(UInt32(key), HotkeyManager.carbonFlags(from: flags))
                            editing = false
                        }, onCancel: { editing = false })
                        .frame(height: 1)
                    }.padding()
                }
        }
    }
}
private struct KeyCaptureRepresentable: NSViewRepresentable {
    let onCaptured: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void
    
    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onCaptured = onCaptured
        v.onCancel = onCancel
        return v
    }
    
    func updateNSView(_ nsView: KeyCaptureView, context: Context) {}
}

private final class KeyCaptureView: NSView {
    var onCaptured: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    private var pendingModifierKeyCode: UInt16?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        pendingModifierKeyCode = nil
        onCaptured?(event.keyCode, event.modifierFlags)
    }
    
    override func flagsChanged(with event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        guard HotkeyManager.isModifierKeyCode(keyCode) else { return }

        if pendingModifierKeyCode == event.keyCode {
            pendingModifierKeyCode = nil
            onCaptured?(event.keyCode, [])
        } else {
            pendingModifierKeyCode = event.keyCode
        }
    }
    
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
