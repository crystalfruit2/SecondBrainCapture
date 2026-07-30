import SwiftUI

/// Four tabs, and Capture is deliberately the first one.
///
/// The dashboard is additive: the screen Alp already uses doesn't change, it
/// just becomes one tab of four, and it's still where the app opens. Zero-
/// friction capture stays exactly where his thumb expects it — everything the
/// dashboard adds is read-and-act, which can afford one extra tap.
struct RootView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var queue: CaptureQueue
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Capture", systemImage: "mic.fill") }

            TodayView()
                .tabItem { Label("Today", systemImage: "calendar") }
                .badge(actionableCount)

            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
        }
    }

    /// Only overdue work earns a badge. Badging everything due today would make
    /// the app nag on a day that's going fine.
    private var actionableCount: Int {
        store.dashboard?.overdueTasks.filter { !$0.done }.count ?? 0
    }
}

#Preview {
    RootView()
        .environmentObject(AppConfig())
        .environmentObject(CaptureQueue())
        .environmentObject(DashboardStore())
}
