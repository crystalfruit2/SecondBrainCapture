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
            VStack(spacing: 16) {
                editor
                statusLine
                HStack(spacing: 12) {
                    recordButton
                    captureButton
                }
            }
            .padding()
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
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Tap the mic and talk, or just type…")
                        .foregroundStyle(.secondary)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
    }

    private var statusLine: some View {
        Group {
            switch status {
            case .idle:
                if speech.isRecording {
                    Label("Listening…", systemImage: "waveform").foregroundStyle(.red)
                } else if !config.hasToken {
                    Label("No token set — open Settings", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if queue.count > 0 {
                    Label("^[\(queue.count) note](inflect: true) waiting to sync…",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                } else {
                    Text(" ")
                }
            case .committing:
                Label("Saving to Inbox…", systemImage: "arrow.up.circle").foregroundStyle(.secondary)
            case .success:
                Label("Saved to Inbox ✅", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .queued(let n):
                Label("Saved on device — will sync (^[\(n) note](inflect: true) queued)",
                      systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.orange)
            case .error(let msg):
                Label(msg, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Label(speech.isRecording ? "Stop" : "Record",
                  systemImage: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(speech.isRecording ? .red : .accentColor)
    }

    private var captureButton: some View {
        Button {
            Task { await capture() }
        } label: {
            Label("Capture", systemImage: "tray.and.arrow.down.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
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
