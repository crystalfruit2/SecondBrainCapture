import SwiftUI

@main
struct SecondBrainCaptureApp: App {
    @StateObject private var config = AppConfig()
    @StateObject private var queue = CaptureQueue()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(config)
                .environmentObject(queue)
                .task {
                    // Let the queue build a service from the current config/token.
                    queue.serviceProvider = {
                        guard config.hasToken else { return nil }
                        return GitHubService(config: config.githubConfig, token: config.token)
                    }
                    // Drain anything left over from a previous session.
                    await queue.flush()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await queue.flush() } }
                }
        }
    }
}
