import SwiftUI

/// The day at a glance: what Rocky wants Alp to know, what's overdue, what's
/// due today, and what's next on the calendar. Read-mostly — the one action it
/// offers is checking something off, because that's the action that matters
/// when you're looking at your day on a phone.
struct TodayView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var queue: CaptureQueue
    @State private var showSettings = false
    @State private var toggleFeedback = 0
    @State private var nudgeSent = false

    private var board: Dashboard? { store.dashboard }

    var body: some View {
        NavigationStack {
            Group {
                // A cached board wins over every empty state: if we've ever seen
                // the day, show it — a lapsed token shouldn't blank the screen.
                if board != nil {
                    content
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings and your day will show up here.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "arrow.clockwise",
                                         title: "Nothing loaded yet",
                                         message: store.lastError ?? "Pull down to fetch your dashboard.")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
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

    private var content: some View {
        List {
            statusSection

            if let rocky = board?.rocky {
                Section {
                    RockyCard(nudge: rocky, onTap: rockyTapAction(for: rocky))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } footer: {
                    if nudgeSent {
                        Text("Queued — Rocky will handle it in your next session.")
                            .transition(.opacity)
                    }
                }
            }

            taskSection(board?.overdueTasks ?? [], title: "Overdue", tint: .orange)
            taskSection(board?.todayTasks ?? [], title: "Today", tint: .secondary)

            if let agenda = board?.agenda, !agenda.isEmpty {
                Section {
                    ForEach(agenda) { item in
                        AgendaRow(item: item)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    SectionHeader(title: "Up next").textCase(nil)
                }
            }

            if isAllClear {
                Section {
                    DashboardPlaceholder(icon: "checkmark.circle",
                                         title: "You're clear",
                                         message: "Nothing overdue, nothing due today.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            footer
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: toggleFeedback)
    }

    private var isAllClear: Bool {
        (board?.overdueTasks.isEmpty ?? true)
            && (board?.todayTasks.isEmpty ?? true)
            && (board?.agenda.isEmpty ?? true)
    }

    /// Only nudges whose vault-side copy promises "tap to ..." get a tap
    /// action — `overdue-tasks` nudges make no such promise and stay inert.
    /// The phone can't run a review or process the Inbox itself, so the tap
    /// queues a capture describing the request; the next Claude session picks
    /// it up from the Inbox and does the actual work.
    private func rockyTapAction(for nudge: RockyNudge) -> (() -> Void)? {
        switch nudge.kind {
        case "review-overdue", "inbox-unprocessed":
            return {
                queue.enqueue("Rocky nudge tapped in the app — please handle now: \(nudge.message)")
                nudgeSent = true
                toggleFeedback += 1
            }
        default:
            return nil
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if store.pendingCount > 0 || store.lastError != nil {
            Section {
                if store.pendingCount > 0 {
                    PendingSyncBadge(count: store.pendingCount)
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
    }

    @ViewBuilder
    private func taskSection(_ tasks: [DashboardTask], title: String, tint: Color) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    TaskRow(task: task) {
                        store.setDone(task, done: !task.done)
                        toggleFeedback += 1
                    }
                    .listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: title, count: tasks.count, tint: tint).textCase(nil)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let generated = board?.generatedAt {
            Section {
                Text("Vault built \(generated.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }
}

#Preview {
    TodayView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
