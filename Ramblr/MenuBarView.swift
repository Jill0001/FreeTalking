import SwiftUI

struct MenuBarView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent dictations").font(.headline)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
            }.padding(14)
            Divider()
            if transcriptionManager.history.isEmpty {
                Text("Completed dictations appear here.")
                    .foregroundStyle(.secondary).padding(18)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(transcriptionManager.history, id: \.self) { text in
                            DictationRow(text: text, files: transcriptionManager.historyFiles[text] ?? []) {
                                transcriptionManager.copyFromHistory(text)
                            }
                            Divider()
                        }
                    }.padding(.horizontal, 8)
                }.frame(height: min(390, CGFloat(transcriptionManager.history.count) * 78))
            }
        }.buttonStyle(.borderless).frame(width: 340)
    }
}

private struct DictationRow: View {
    let text: String
    let files: [String]
    let copy: () -> Void
    @State private var hovering = false
    @State private var copyID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                copy()
                copyID = UUID()
            } label: {
                HStack(spacing: 8) {
                    Text(text)
                        .font(.body)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label(copyID == nil ? "Copy" : "Copied",
                          systemImage: copyID == nil ? "doc.on.doc" : "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(hovering ? 0.18 : 0.10), in: Capsule())
                        .fixedSize()
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(Color.accentColor.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Copy full transcript")
            .accessibilityLabel("Copy transcript")
            .accessibilityValue(text)
            ForEach(files, id: \.self) { path in
                if FileManager.default.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: url.pathExtension == "wav" ? "waveform" : "doc.text")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 26)
                    }
                    .help("Show " + url.lastPathComponent + " in Finder")
                    .accessibilityLabel(url.pathExtension == "wav" ? "Show recording in Finder" : "Show transcript in Finder")
                }
            }
        }
        .padding(.vertical, 3)
        .task(id: copyID) {
            guard copyID != nil else { return }
            do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
            copyID = nil
        }
    }
}
