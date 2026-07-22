import Foundation
import Speech
import AVFoundation

/// Wraps SFSpeechRecognizer + AVAudioEngine for on-device dictation.
/// Publishes the live transcript of the current recording session.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false

    /// Text from completed segments so far this session. iOS finalizes long
    /// dictations in segments — `isFinal` fires at natural pauses, not only
    /// when the user stops — and each segment's result only covers *that*
    /// segment. We stitch segments together here instead of tearing the mic
    /// down on every `isFinal`, which used to silently stop recording (and
    /// erase what came before) at the end of every sentence.
    private var finalizedText = ""

    /// Ask for both speech-recognition and microphone permission.
    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }

        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start() throws {
        task?.cancel()
        task = nil
        transcript = ""
        finalizedText = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        if !tapInstalled {
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            tapInstalled = true
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        beginSegment()
    }

    /// Starts (or restarts, mid-session) a recognition request without
    /// touching the audio engine, so listening never actually stops between
    /// segments.
    private func beginSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let segment = result.bestTranscription.formattedString
                    self.transcript = self.finalizedText.isEmpty ? segment : self.finalizedText + " " + segment
                    if result.isFinal {
                        self.finalizedText = self.transcript
                    }
                }
                guard error != nil || (result?.isFinal ?? false) else { return }
                if self.isRecording {
                    self.beginSegment()   // segment ended at a pause — keep listening
                } else {
                    // Graceful stop: this is the real, final result flushed by
                    // endAudio(). Just tidy up — don't cancel().
                    self.task = nil
                    self.request = nil
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Ending (not cancelling) the request lets the recognizer flush its
        // real final transcript through the completion handler above.
        // Cancelling here used to race that flush and hand back an
        // empty/truncated result that clobbered whatever was just said.
        request?.endAudio()
    }
}
