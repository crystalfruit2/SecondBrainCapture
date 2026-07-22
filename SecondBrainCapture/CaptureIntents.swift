import AppIntents

struct OpenCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Capture"
    static var description = IntentDescription(
        "Opens Second Brain Capture — built for Back Tap."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct SecondBrainCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCaptureIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Open a capture in \(.applicationName)"
            ],
            shortTitle: "Open Capture",
            systemImageName: "mic.circle.fill"
        )
    }
}
