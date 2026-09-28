import SwiftUI

/// Health, Projects and Finance share one tab so the bottom bar doesn't fill
/// up with single-purpose screens — a segmented control switches between
/// them instead of each claiming its own icon. The shell (nav chrome,
/// settings, no-token/loading states) lives here once; each section is a
/// content-only view. Market moved to the To Do tab's Buy segment (2026-09-28).
struct FeaturesView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var push: PushController
    @State private var showSettings = false
    @State private var section: Segment = .health

    enum Segment: String, CaseIterable, Identifiable {
        case health = "Health", projects = "Projects", finance = "Finance"
        var id: String { rawValue }
    }

    private var board: Dashboard? { store.dashboard }

    var body: some View {
        NavigationStack {
            Group {
                if board != nil {
                    selectedContent
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings to see this.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "arrow.clockwise",
                                         title: "Nothing loaded yet",
                                         message: store.lastError ?? "Pull down to fetch.")
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section) {
                        ForEach(Segment.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(config)
            }
        }
        .task { await store.refreshIfStale() }
        .onChange(of: push.openFinanceTick) { _, _ in section = .finance }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch section {
        case .health: HealthLogContent()
        case .projects: ProjectsContent()
        case .finance: FinanceContent()
        }
    }
}

#Preview {
    FeaturesView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
