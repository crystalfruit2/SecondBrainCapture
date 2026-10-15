import SwiftUI

/// The facts Alp keeps in his pocket for the next few days: **when, where,
/// what's my part**. Added 2026-10-14 because Rocky's reports ("RL lecture Thu
/// 14:15, room -1607, be there") lived only in terminal scrollback or deep in a
/// vault note. Each card is a Rocky-written card from `Areas/Pocket.md`, a
/// mirrored calendar event, or both merged vault-side. The cards are read-only
/// here (the vault note is the place to edit them). Above them sits
/// **Important**, the undated must-remember bullets of `## Important` in the
/// same note — those Alp adds, edits and deletes from the phone, offline-first
/// like the To-Do list (2026-10-15).
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
                        PocketList(items: board.pocket, facts: board.pocketFacts, now: context.date)
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
    let facts: [PocketFact]
    let now: Date
    @State private var editing: PocketFact?
    @State private var feedback = 0

    var body: some View {
        let groups = PocketClock.groups(items, now: now)
        List {
            if store.factPendingCount > 0 || store.lastError != nil {
                Section {
                    if store.factPendingCount > 0 {
                        PendingSyncBadge(count: store.factPendingCount)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    if let error = store.lastError {
                        DashboardErrorBanner(message: error)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }

            // Always here — with or without cards, with or without facts.
            Section {
                if facts.isEmpty {
                    Text("Codes, names, small things you must not forget. Type “Door code — 4417”.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(facts) { fact in
                    Button { editing = fact } label: { PocketFactRow(fact: fact) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.deleteFact(fact)
                                feedback += 1
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if !fact.detail.isEmpty {
                                Button { UIPasteboard.general.string = fact.detail } label: {
                                    Label("Copy detail", systemImage: "doc.on.doc")
                                }
                            }
                            Button { editing = fact } label: { Label("Edit", systemImage: "pencil") }
                        }
                }
                PocketFactAddRow { text in
                    store.addFact(text)
                    feedback += 1
                }
            } header: {
                SectionHeader(title: "Important", count: facts.isEmpty ? nil : facts.count,
                              tint: .accentColor)
                    .textCase(nil)
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
        .sensoryFeedback(.success, trigger: feedback)
        .sheet(item: $editing) { fact in
            PocketFactEditSheet(fact: fact) { label, detail in
                store.editFact(fact, label: label, detail: detail)
                feedback += 1
            }
        }
    }
}

/// Label bold, detail underneath — the detail is the thing you came for
/// ("4417"), so it gets the room.
private struct PocketFactRow: View {
    let fact: PocketFact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.label)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !fact.detail.isEmpty {
                Text(fact.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One field: `label — detail` (the em dash is optional). Modelled on
/// `TodoAddBar`, minus the date controls a fact doesn't have.
private struct PocketFactAddRow: View {
    let onAdd: (String) -> Void
    @State private var text = ""

    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("Add something to remember", text: $text)
                .submitLabel(.done)
                .onSubmit(add)
            if canAdd {
                Button("Add", action: add).fontWeight(.semibold)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        onAdd(text)
        text = ""
    }
}

private struct PocketFactEditSheet: View {
    let fact: PocketFact
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var detail: String

    init(fact: PocketFact, onSave: @escaping (String, String) -> Void) {
        self.fact = fact
        self.onSave = onSave
        _label = State(initialValue: fact.label)
        _detail = State(initialValue: fact.detail)
    }

    private var canSave: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Door code B-Bau", text: $label)
                }
                Section("Detail") {
                    TextField("4417", text: $detail, axis: .vertical)
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(label, detail)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
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
