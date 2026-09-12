import SwiftUI

/// Market, Health, Projects and Finance share one tab so the bottom bar doesn't fill
/// up with single-purpose screens — a segmented control switches between
/// them instead of each claiming its own icon. The shell (nav chrome,
/// settings, no-token/loading states) lives here once; each section is a
/// content-only view.
struct FeaturesView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @State private var showSettings = false
    @State private var section: Segment = .market

    enum Segment: String, CaseIterable, Identifiable {
        case market = "Market", health = "Health", projects = "Projects", finance = "Finance"
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
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch section {
        case .market: MarketListContent()
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
