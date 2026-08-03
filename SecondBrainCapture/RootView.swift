import SwiftUI

/// Four tabs, and Capture is deliberately the first one.
///
/// The dashboard is additive: the screen Alp already uses doesn't change, it
/// just becomes one tab of four, and it's still where the app opens. Zero-
/// friction capture stays exactly where his thumb expects it — everything the
/// dashboard adds is read-and-act, which can afford one extra tap.
///
/// Today absorbs what used to be a separate Tasks tab (same overdue/today/
/// upcoming buckets, just one screen instead of two with overlapping
/// questions). Market, Health and Projects share a single Features tab with
/// an in-tab segmented switch, rather than each claiming its own icon — the
/// bar was heading toward seven icons before this consolidation.
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

            FeaturesView()
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }

            CompanionView()
                .tabItem { Label("Companion", systemImage: "sparkles") }
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
