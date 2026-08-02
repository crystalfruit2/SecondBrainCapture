import SwiftUI

struct ContentView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var queue: CaptureQueue
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var ocr = TextRecognizer()

    @State private var draft = ""
    @State private var baseText = ""          // editor text captured when recording starts
    @State private var status: Status = .idle
    @State private var showSettings = false
    @State private var showCamera = false
    @State private var photo: UIImage?        // prepared (downscaled) attachment
    @FocusState private var editorFocused: Bool

    enum Status: Equatable {
        case idle, committing, success, queued(Int), error(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    editor
                    if let photo {
                        photoPreview(photo)
                    }
                    statusLine
                    // Record and Photo are the two ways text gets *into* the
                    // draft; Capture is what sends it. Keeping that split across
                    // two rows leaves Capture full-width and unmissable.
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            recordButton
                            photoButton
                        }
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
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { picked in
                    Task { await attach(picked) }
                }
                .ignoresSafeArea()
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
                if ocr.isRecognizing {
                    statusBadge("Reading text…", icon: "text.viewfinder", color: .secondary)
                } else if speech.isRecording {
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
                HStack(spacing: 5) {
                    if item.isPhoto {
                        Image(systemName: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.preview)
                        .font(.footnote)
                        .lineLimit(2)
                }
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

    private var photoButton: some View {
        Button {
            showCamera = true
        } label: {
            Label(photo == nil ? "Photo" : "Retake", systemImage: "camera.fill")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .disabled(ocr.isRecognizing)
    }

    /// The attached photo, with a way to drop it. Shown at a readable size so a
    /// blurry shot is caught here rather than in the vault a week later.
    private func photoPreview(_ image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                photo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(8)
            .accessibilityLabel("Remove photo")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .disabled(!hasSomethingToCapture || status == .committing || ocr.isRecognizing)
    }

    /// A photo is a note in its own right — a whiteboard shot with no legible
    /// text is still worth keeping, so an empty draft doesn't block Capture.
    private var hasSomethingToCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil
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

    /// Downscale the shot, read its text, and drop that text into the draft so
    /// it can be corrected before it's committed. Appended rather than
    /// substituted — a photo may be adding to something already dictated.
    private func attach(_ image: UIImage) async {
        let prepared = ImageStore.prepared(image)
        photo = prepared
        status = .idle

        let text = await ocr.recognize(prepared)
        guard !text.isEmpty else { return }   // no legible text; the photo is the note
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? text : existing + "\n\n" + text
        baseText = draft   // keep dictation appending after the OCR text, not over it
    }

    private func capture() async {
        if speech.isRecording { speech.stop() }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSomethingToCapture else { return }
        guard config.hasToken else {
            status = .error("No token. Open Settings and add a GitHub token.")
            return
        }
        // Persist first, then try to sync. The note is safe on disk the instant
        // the user taps Capture, even with no signal.
        status = .committing
        let now = Date()
        // Staging the image before enqueuing keeps the queue's promise: nothing
        // is queued that isn't already durable on disk.
        let imageFilename = photo.flatMap { ImageStore.save($0, date: now) }
        queue.enqueue(text, createdAt: now, imageFilename: imageFilename)
        draft = ""
        baseText = ""
        photo = nil

        let drained = await queue.flush()
        status = drained ? .success : .queued(queue.count)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppConfig())
        .environmentObject(CaptureQueue())
}
