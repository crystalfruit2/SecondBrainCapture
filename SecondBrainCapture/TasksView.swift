import SwiftUI

/// Everything open, bucketed. Where Today answers "what now?", this answers
/// "what's on me at all?" — and it's the screen built for acting: tap to
/// complete, swipe to defer, each one landing as a single-line commit.
struct TasksView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @State private var showSettings = false
    @State private var toggleFeedback = 0
    @State private var showCompleted = false

    private var board: Dashboard? { store.dashboard }

    var body: some View {
        NavigationStack {
            Group {
                if board != nil {
                    content
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings to see your tasks.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "arrow.clockwise",
                                         title: "Nothing loaded yet",
                                         message: store.lastError ?? "Pull down to fetch your tasks.")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show completed", isOn: $showCompleted)
                        Divider()
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
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
            if store.pendingCount > 0 {
                Section {
                    PendingSyncBadge(count: store.pendingCount)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            taskSection(.overdue, tint: .orange)
            taskSection(.today, tint: .secondary)
            taskSection(.upcoming, tint: .secondary)

            if visibleTasks(in: .overdue).isEmpty
                && visibleTasks(in: .today).isEmpty
                && visibleTasks(in: .upcoming).isEmpty {
                Section {
                    DashboardPlaceholder(icon: "checkmark.circle",
                                         title: "Inbox zero",
                                         message: showCompleted
                                            ? "No tasks in the vault right now."
                                            : "Everything open is done. Turn on “Show completed” to see the rest.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                Text("Swipe a task → Done or Defer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: toggleFeedback)
    }

    /// Completed tasks are hidden by default — the point of this screen is what's
    /// left, not what's behind. They stay one toggle away for the satisfaction.
    private func visibleTasks(in bucket: TaskBucket) -> [DashboardTask] {
        let all = board?.tasks(in: bucket) ?? []
        return showCompleted ? all : all.filter { !$0.done }
    }

    @ViewBuilder
    private func taskSection(_ bucket: TaskBucket, tint: Color) -> some View {
        let tasks = visibleTasks(in: bucket)
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    TaskRow(task: task) {
                        toggle(task)
                    }
                    .listRowInsets(EdgeInsets())
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            toggle(task)
                        } label: {
                            Label(task.done ? "Reopen" : "Done",
                                  systemImage: task.done ? "arrow.uturn.backward" : "checkmark")
                        }
                        .tint(task.done ? .orange : .green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            store.postpone(task)
                            toggleFeedback += 1
                        } label: {
                            Label("Defer", systemImage: "calendar.badge.clock")
                        }
                        .tint(.indigo)
                    }
                }
            } header: {
                SectionHeader(title: bucket.title, count: tasks.count, tint: tint).textCase(nil)
            }
        }
    }

    private func toggle(_ task: DashboardTask) {
        store.setDone(task, done: !task.done)
        toggleFeedback += 1
    }
}

#Preview {
    TasksView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
