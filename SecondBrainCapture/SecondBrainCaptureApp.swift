import SwiftUI

@main
struct SecondBrainCaptureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var push = PushController.shared
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
                .environmentObject(push)
                .task {
                    // Let the queue build a service from the current config/token.
                    queue.serviceProvider = {
                        guard config.hasToken else { return nil }
                        return GitHubService(config: config.githubConfig, token: config.token)
                    }
                    dashboard.serviceProvider = queue.serviceProvider
                    dashboard.dashboardPath = { config.dashboardPath }
                    dashboard.marketListPath = { config.marketListPath }
                    // Faz S-G4a: Sentinel pushes. Permission is asked once, on launch with a token.
                    push.serviceProvider = queue.serviceProvider
                    push.onFinancePush = { await dashboard.refresh() }
                    if config.hasToken { await push.requestIfNeeded() }
                    #if DEBUG
                    // Simulator screenshots: `xcrun simctl launch booted com.alp.SecondBrainCapture -sbcOpenFinance`
                    if CommandLine.arguments.contains("-sbcOpenFinance") { push.openFinanceTick += 1 }
                    #endif
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
