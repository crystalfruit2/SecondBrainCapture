import SwiftUI

/// Plain logging, no lecturing: three one-tap buttons for the things Alp
/// tracks most often, plus a free-text field for anything else (mood, food,
/// a workout note). Every tap appends a bullet to today's daily note's
/// `### Health log` section — there's nothing to toggle or undo, because a
/// log entry is a fact about the day, not a task. Content-only: `FeaturesView`
/// owns the shell shared across Market/Health/Projects.
struct HealthLogContent: View {
    @EnvironmentObject var store: DashboardStore
    @State private var logFeedback = 0
    @State private var noteText = ""
    @FocusState private var noteFieldFocused: Bool

    private var loggedToday: [String] { store.dashboard?.health.loggedToday ?? [] }

    private static let quickLogs: [(label: String, emoji: String)] = [
        ("Cigarette", "🚬"),
        ("Energy drink", "⚡"),
        ("Workout", "💪"),
    ]

    var body: some View {
        List {
            if store.healthPendingCount > 0 {
                Section {
                    PendingSyncBadge(count: store.healthPendingCount)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(Self.quickLogs, id: \.label) { entry in
                        Button {
                            log(entry.emoji)
                        } label: {
                            VStack(spacing: 4) {
                                Text(entry.emoji).font(.system(size: 26))
                                Text(entry.label).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 4)
            } header: {
                SectionHeader(title: "Quick log").textCase(nil)
            }

            Section {
                if loggedToday.isEmpty {
                    Text("Nothing logged today yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(loggedToday.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.subheadline)
                            .padding(.vertical, 2)
                    }
                }
            } header: {
                SectionHeader(title: "Logged today", count: loggedToday.isEmpty ? nil : loggedToday.count).textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: logFeedback)
        .safeAreaInset(edge: .bottom) { noteBar }
    }

    private var noteBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)
            TextField("Log something else", text: $noteText)
                .focused($noteFieldFocused)
                .submitLabel(.done)
                .onSubmit(logNote)
            if !noteText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Log", action: logNote)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func log(_ text: String) {
        store.logHealth(text)
        logFeedback += 1
    }

    private func logNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.logHealth(trimmed)
        noteText = ""
        logFeedback += 1
    }
}

#Preview {
    NavigationStack { HealthLogContent() }
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
