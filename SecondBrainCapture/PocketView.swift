import SwiftUI

/// The facts Alp keeps in his pocket for the next few days: **when, where,
/// what's my part**. Added 2026-10-14 because Rocky's reports ("RL lecture Thu
/// 14:15, room -1607, be there") lived only in terminal scrollback or deep in a
/// vault note. Each card is a Rocky-written card from `Areas/Pocket.md`, a
/// mirrored calendar event, or both merged vault-side. Read-only: the vault
/// note is the place to edit.
struct PocketView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let board = store.dashboard {
                    // Re-evaluated every minute so finished items drop off while the tab is open.
                    TimelineView(.everyMinute) { context in
                        PocketList(items: board.pocket, now: context.date)
                    }
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings and your cards will show up here.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "arrow.clockwise",
                                         title: "Nothing loaded yet",
                                         message: store.lastError ?? "Pull down to fetch your cards.")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
}

private struct PocketList: View {
    @EnvironmentObject var store: DashboardStore
    let items: [PocketItem]
    let now: Date

    var body: some View {
        let groups = PocketClock.groups(items, now: now)
        List {
            if let error = store.lastError {
                Section {
                    DashboardErrorBanner(message: error)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if groups.isEmpty {
                Section {
                    DashboardPlaceholder(icon: "pin",
                                         title: "Nothing coming up",
                                         message: "Rocky adds cards here when there's somewhere to be. The vault note is Areas/Pocket.md.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            ForEach(groups, id: \.label) { group in
                Section {
                    ForEach(group.items) { item in
                        PocketCard(item: item)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    SectionHeader(title: group.label,
                                  tint: group.label == "Today" ? .accentColor : .secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }
}

/// Time and place first, big. They're what Alp needs when he's already walking.
struct PocketCard: View {
    let item: PocketItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.timeLabel)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(item.isAllDay ? Color.secondary : Color.accentColor)

            if let place = item.place {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: place.hasPrefix("Online") ? "video.fill" : "mappin")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Text(place)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.hasDetails ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if item.hasDetails {
                VStack(alignment: .leading, spacing: 4) {
                    if let part = item.part { detail("hand.point.right", part, tint: .orange) }
                    if let bring = item.bring { detail("backpack", bring, tint: .blue) }
                    ForEach(item.notes, id: \.self) { detail("note.text", $0, tint: .secondary) }
                }
                .padding(.top, 2)
            }

            if let source = item.source {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    PocketView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
