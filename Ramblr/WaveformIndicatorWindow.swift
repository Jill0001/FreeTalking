import SwiftUI
import AppKit

enum IndicatorMode {
    case waveform
    case transcribing
}

final class WaveformIndicatorWindow: ObservableObject {
    static let shared = WaveformIndicatorWindow()
    private var window: NSPanel?
    private var positionTimer: Timer?
    private var lastPositionSource = ""
    private var hostingController: NSHostingController<WaveformIndicatorView>?
    private var waveformModel = WaveformModel()
    @Published var mode: IndicatorMode = .waveform
    @Published var previewText: String?
    @Published var opacity: Double = 0.0
    @Published var clipboardOnly: Bool = false
    @Published var showOutputMode: Bool = false
    
    private init() {}
    
    private var transcriptHeight: CGFloat = 18

    func measuredTranscript(height: CGFloat) {
        guard height != transcriptHeight else { return }
        transcriptHeight = height
        if let window, window.isVisible, window.frame.size != indicatorSize {
            window.setContentSize(indicatorSize)
            updatePosition(initial: true)
        }
    }

    private var indicatorSize: NSSize {
        if previewText != nil {
            let screenHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
            return NSSize(width: 368, height: min(transcriptHeight + 32, floor(screenHeight * 0.65)))
        }
        return NSSize(width: showOutputMode ? 200 : 60, height: 20)
    }

    func show() {
        // If already shown, just return
        if let window = window, window.isVisible {
            window.setContentSize(indicatorSize)
            updatePosition(initial: true)
            return
        }
        
        let waveformView = WaveformIndicatorView(model: waveformModel, windowModel: self)

        let hosting = NSHostingController(rootView: waveformView)
        hostingController = hosting

        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.backgroundColor = NSColor.clear
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level.statusBar
        panel.setContentSize(indicatorSize)
        
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = panel
        updatePosition(initial: true)
        positionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updatePosition(initial: false)
        }
        positionTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        // Start with opacity 0 and fade in
        opacity = 0.0
        panel.orderFront(nil)
        
        // Animate fade in
        withAnimation(.easeOut(duration: 0.2)) {
            opacity = 1.0
        }
    }
    
    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.positionTimer?.invalidate()
            self.positionTimer = nil
            self.opacity = 0.0
            self.window?.orderOut(nil)
            self.transcriptHeight = 18
            self.window = nil
            self.hostingController = nil
            self.previewText = nil
        }
    }
    
    func updateAudioLevels(_ levels: [Float]) {
        waveformModel.updateLevels(levels)
    }
    
    func showWaveform(clipboardOnly: Bool = false, showOutputMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.mode = .waveform
            self?.clipboardOnly = clipboardOnly
            self?.showOutputMode = showOutputMode
            self?.show()
        }
    }
    
    func showTranscribing(keepingPreview: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            if !keepingPreview { self?.previewText = nil }
            self?.mode = .transcribing
            self?.show()
        }
    }
    
    private func updatePosition(initial: Bool) {
        guard let window = window else { return }
        let caret = RecordingIndicatorPlacement.caretRect()
        let source = RecordingIndicatorPlacement.locationSource
        if source != lastPositionSource {
            logInfo("Recording indicator position: \(source)")
            lastPositionSource = source
        }
        if let anchor = caret,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            window.setFrameOrigin(RecordingIndicatorPlacement.origin(near: anchor, panelSize: window.frame.size,
                                                                    visibleFrame: screen.visibleFrame))
        } else if initial, let screen = NSScreen.main {
            // Keep recording visible even when the app exposes no text geometry.
            let frame = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.maxY - window.frame.height - 8))
        }
    }

}

/// The document keeps the entire recording. Follow new lines only while the reader is at the bottom.
private struct TranscriptScrollView: NSViewRepresentable {
    let text: String
    let measured: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero)
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = false
        view.font = .systemFont(ofSize: 14)
        view.textColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text,
              let container = view.textContainer, let layout = view.layoutManager else { return }
        let follow = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 2
        // The panel is 368 points wide with 10 points of padding on each side.
        let width: CGFloat = 348
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.string = text
        layout.ensureLayout(for: container)
        let height = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))
        view.setFrameSize(NSSize(width: width, height: height))
        measured(height)
        if follow {
            view.scrollToVisible(NSRect(x: 0, y: max(0, height - 1), width: 1, height: 1))
        }
    }
}

private struct PulsingDotsView: View {
    @State private var pulse1 = false
    @State private var pulse2 = false
    @State private var pulse3 = false
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.white.opacity(pulse1 ? 1.0 : 0.3))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse1)
            
            Circle()
                .fill(Color.white.opacity(pulse2 ? 1.0 : 0.3))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse2)
            
            Circle()
                .fill(Color.white.opacity(pulse3 ? 1.0 : 0.3))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse3)
        }
        .onAppear {
            // Start animations with staggered timing
            pulse1 = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pulse2 = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pulse3 = true
            }
        }
        .onDisappear {
            pulse1 = false
            pulse2 = false
            pulse3 = false
        }
    }
}

private struct WaveformIndicatorView: View {
    @ObservedObject var model: WaveformModel
    @ObservedObject var windowModel: WaveformIndicatorWindow

    var body: some View {
        VStack(spacing: 4) {
            if let preview = windowModel.previewText {
                TranscriptScrollView(text: preview, measured: windowModel.measuredTranscript)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 8))
            }
            controls
        }
        .opacity(windowModel.opacity)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            // Waveform / transcribing pill
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.8))
                    .frame(width: 60, height: 20)

                Group {
                    switch windowModel.mode {
                    case .waveform:
                        WaveformView(model: model)
                            .frame(width: 50, height: 12)
                    case .transcribing:
                        PulsingDotsView()
                            .frame(width: 50, height: 12)
                    }
                }
            }

            // Output mode pill (when auto-paste is relevant)
            if windowModel.showOutputMode {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.8))
                        .frame(height: 20)

                    Text(windowModel.clipboardOnly ? "clipboard" : "auto-paste")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                }
                .fixedSize()
                .onTapGesture {
                    windowModel.clipboardOnly.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }
}

