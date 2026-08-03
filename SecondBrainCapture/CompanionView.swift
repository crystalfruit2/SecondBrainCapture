import SwiftUI

/// Read-only glance at the three "Companion organs" — Life-Threads,
/// Decision-Log, Idea-Garden — that Claude feeds during normal vault work but
/// Alp never sees unless he opens Obsidian. No writes here on purpose: these
/// change through real conversations, not phone taps.
struct CompanionView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @State private var showSettings = false
    @State private var section: Segment = .threads

    enum Segment: String, CaseIterable, Identifiable {
        case threads = "Threads", decisions = "Decisions", seeds = "Ideas"
        var id: String { rawValue }
    }

    private var companion: CompanionData? { store.dashboard?.companion }

    var body: some View {
        NavigationStack {
            Group {
                if let companion, !companion.isEmpty {
                    content(companion)
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings to see this.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "sparkles",
                                         title: "Nothing here yet",
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
    private func content(_ companion: CompanionData) -> some View {
        List {
            switch section {
            case .threads: threadsSection(companion.threads)
            case .decisions: decisionsSection(companion.decisions)
            case .seeds: seedsSection(companion.seeds)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private func threadsSection(_ threads: [CompanionThread]) -> some View {
        if threads.isEmpty {
            emptyRow("No active threads right now.")
        } else {
            Section {
                ForEach(threads) { thread in
                    ThreadCard(thread: thread).listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: "Life threads", count: threads.count).textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func decisionsSection(_ decisions: [CompanionDecision]) -> some View {
        if decisions.isEmpty {
            emptyRow("No recent decisions logged.")
        } else {
            Section {
                ForEach(decisions) { decision in
                    DecisionCard(decision: decision).listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: "Recent decisions", count: decisions.count).textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func seedsSection(_ seeds: [CompanionSeed]) -> some View {
        if seeds.isEmpty {
            emptyRow("No open ideas planted yet.")
        } else {
            Section {
                ForEach(seeds) { seed in
                    SeedCard(seed: seed).listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: "Ideas", count: seeds.count).textCase(nil)
            }
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

private struct ThreadCard: View {
    let thread: CompanionThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(thread.status)
                Text(thread.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            if let movement = thread.latestMovement {
                Text(movement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let next = thread.nextPull {
                Label(next, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(3)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct DecisionCard: View {
    let decision: CompanionDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(decision.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let date = decision.date {
                    Text(date).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            if let choice = decision.choice {
                Text(choice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let followUp = decision.followUp {
                Text(followUp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .lineLimit(2)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SeedCard: View {
    let seed: CompanionSeed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(seed.title, systemImage: "sparkle")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let summary = seed.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

#Preview {
    CompanionView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
