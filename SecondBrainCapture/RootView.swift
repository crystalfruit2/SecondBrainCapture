import SwiftUI

/// Four tabs, and Capture is deliberately the first one.
///
/// The dashboard is additive: the screen Alp already uses doesn't change, it
/// just becomes one tab of four, and it's still where the app opens. Zero-
/// friction capture stays exactly where his thumb expects it — everything the
/// dashboard adds is read-and-act, which can afford one extra tap.
///
/// To Do (2026-09-28) replaces the old Today tab: Alp's own lists (today /
/// week / errands / buy) in front, the Daily-note work tasks behind a Vault
/// segment. Health, Projects and Finance share a single Features tab with an
/// in-tab segmented switch, rather than each claiming its own icon — the bar
/// was heading toward seven icons before this consolidation.
struct RootView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var queue: CaptureQueue
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var push: PushController
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("Capture", systemImage: "mic.fill") }
                .tag(0)

            TodoView()
                .tabItem { Label("To Do", systemImage: "checklist") }
                .badge(actionableCount)
                .tag(1)

            FeaturesView()
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
                .badge(store.dashboard?.finance?.unreadAlerts ?? 0)   // Faz S-G4a: unread Sentinel alerts
                .tag(2)

            CompanionView()
                .tabItem { Label("Companion", systemImage: "sparkles") }
                .tag(3)
        }
        .onChange(of: push.openFinanceTick) { _, _ in tab = 2 }
        .onChange(of: push.openTodoTick) { _, _ in tab = 1 }
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("-sbcTodoSegment") { tab = 1 }   // simulator screenshots
            #endif
        }
    }

    /// Only overdue work earns a badge. Badging everything due today would make
    /// the app nag on a day that's going fine.
    private var actionableCount: Int {
        let vault = store.dashboard?.overdueTasks.filter { !$0.done }.count ?? 0
        let own = (store.dashboard?.todo ?? []).filter { item in
            guard item.recur == nil, !item.isDone() else { return false }
            if case .overdue = item.bucket() { return true }
            return false
        }.count
        return vault + own
    }
}

#Preview {
    RootView()
        .environmentObject(AppConfig())
        .environmentObject(CaptureQueue())
        .environmentObject(DashboardStore())
        .environmentObject(PushController.shared)
}
