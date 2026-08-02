import SwiftUI

@main
struct SecondBrainCaptureApp: App {
    @StateObject private var config = AppConfig()
    @StateObject private var queue = CaptureQueue()
    @StateObject private var dashboard = DashboardStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(config)
                .environmentObject(queue)
                .environmentObject(dashboard)
                .task {
                    // Let the queue build a service from the current config/token.
                    queue.serviceProvider = {
                        guard config.hasToken else { return nil }
                        return GitHubService(config: config.githubConfig, token: config.token)
                    }
                    dashboard.serviceProvider = queue.serviceProvider
                    dashboard.dashboardPath = { config.dashboardPath }
                    dashboard.marketListPath = { config.marketListPath }
                    // Drain anything left over from a previous session.
                    await queue.flush()
                    await dashboard.refreshIfStale()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await queue.flush()
                        // Buckets are date-dependent: "overdue" and "today" go
                        // wrong the moment the app is reopened on a new day.
                        await dashboard.refreshIfStale()
                    }
                }
        }
    }
}
