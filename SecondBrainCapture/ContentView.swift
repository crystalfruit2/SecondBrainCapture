import SwiftUI

struct ContentView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var queue: CaptureQueue
    @StateObject private var speech = SpeechRecognizer()

    @State private var draft = ""
    @State private var baseText = ""          // editor text captured when recording starts
    @State private var status: Status = .idle
    @State private var showSettings = false
    @FocusState private var editorFocused: Bool

    enum Status: Equatable {
        case idle, committing, success, queued(Int), error(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    editor
                    statusLine
                    HStack(spacing: 12) {
                        recordButton
                        captureButton
                    }
                    if !queue.recent.isEmpty {
                        recentSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Capture")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(config)
            }
            .onChange(of: speech.transcript) { _, newValue in
                draft = baseText.isEmpty ? newValue : baseText + " " + newValue
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .focused($editorFocused)
            .scrollContentBackground(.hidden)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Tap the mic and talk, or just type…")
                        .foregroundStyle(.secondary)
                        .padding(22)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 160, maxHeight: 260)
    }

    private var statusLine: some View {
        Group {
            switch status {
            case .idle:
                if speech.isRecording {
                    statusBadge("Listening…", icon: "waveform", color: .red)
                } else if !config.hasToken {
                    statusBadge("No token set — open Settings", icon: "exclamationmark.triangle.fill", color: .orange)
                } else if queue.count > 0 {
                    statusBadge("^[\(queue.count) note](inflect: true) waiting to sync…",
                                 icon: "arrow.triangle.2.circlepath", color: .orange)
                } else {
                    EmptyView()
                }
            case .committing:
                statusBadge("Saving to Inbox…", icon: "arrow.up.circle", color: .secondary)
            case .success:
                statusBadge("Saved to Inbox", icon: "checkmark.circle.fill", color: .green)
            case .queued(let n):
                statusBadge("Saved on device (^[\(n) note](inflect: true) queued)",
                             icon: "tray.and.arrow.down.fill", color: .orange)
            case .error(let msg):
                statusBadge(msg, icon: "xmark.octagon.fill", color: .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 8) {
                ForEach(queue.recent) { item in
                    recentRow(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentRow(_ item: RecentCapture) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.synced ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(item.synced ? .green : .orange)
                .imageScale(.small)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.footnote)
                    .lineLimit(2)
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Label(speech.isRecording ? "Stop" : "Record",
                  systemImage: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .tint(speech.isRecording ? .red : .accentColor)
    }

    private var captureButton: some View {
        Button {
            Task { await capture() }
        } label: {
            Label("Capture", systemImage: "tray.and.arrow.down.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .committing)
    }

    private func toggleRecording() async {
        if speech.isRecording {
            speech.stop()
            return
        }
        guard await speech.requestAuthorization() else {
            status = .error("Microphone / speech permission denied.")
            return
        }
        status = .idle
        baseText = draft
        do {
            try speech.start()
        } catch {
            status = .error("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func capture() async {
        if speech.isRecording { speech.stop() }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard config.hasToken else {
            status = .error("No token. Open Settings and add a GitHub token.")
            return
        }
        // Persist first, then try to sync. The note is safe on disk the instant
        // the user taps Capture, even with no signal.
        status = .committing
        queue.enqueue(text)
        draft = ""
        baseText = ""

        let drained = await queue.flush()
        status = drained ? .success : .queued(queue.count)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppConfig())
        .environmentObject(CaptureQueue())
}
