import SwiftUI

/// Everything Alp has to do or get, in five segments: **Today · Week ·
/// Errands · Buy · Vault**. Replaces the old Today tab (2026-09-28), which
/// showed every checkbox scraped from the Daily note as one long list — 69
/// paragraph-length lines the day this was built. The first four segments are
/// Alp's own short lists (`Areas/To-Do.md`, `Areas/Market-List.md`); the
/// Daily-note work tasks keep their buckets but move to the Vault segment,
/// trimmed to a first clause and expandable on tap.
struct TodoView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var queue: CaptureQueue
    @EnvironmentObject var push: PushController
    @State private var segment: Segment = .today
    @State private var showSettings = false
    @State private var showCompleted = false
    @State private var feedback = 0
    @State private var nudgeSent = false
    @State private var expanded: Set<String> = []

    enum Segment: String, CaseIterable, Identifiable {
        case today = "Today", week = "Week", errands = "Errands", buy = "Buy", vault = "Vault"
        var id: String { rawValue }
    }

    private var board: Dashboard? { store.dashboard }
    private var now: Date { Date() }

    var body: some View {
        NavigationStack {
            Group {
                if board != nil {
                    content
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings and your list will show up here.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "arrow.clockwise",
                                         title: "Nothing loaded yet",
                                         message: store.lastError ?? "Pull down to fetch your list.")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("To Do")
            .navigationBarTitleDisplayMode(.inline)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Segment", selection: $segment) {
                    ForEach(Segment.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(config)
            }
        }
        .task { await store.refreshIfStale() }
        .onChange(of: push.openTodoTick) { _, _ in segment = .today }
        .onAppear {
            #if DEBUG
            // Simulator screenshots: `simctl launch booted com.alp.SecondBrainCapture -sbcTodoSegment Week`
            if let i = CommandLine.arguments.firstIndex(of: "-sbcTodoSegment"),
               i + 1 < CommandLine.arguments.count,
               let s = Segment(rawValue: CommandLine.arguments[i + 1]) {
                segment = s
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .today: TodayList(showCompleted: showCompleted, nudgeSent: $nudgeSent, feedback: $feedback)
        case .week: WeekList(showCompleted: showCompleted, feedback: $feedback)
        case .errands: ErrandsList(showCompleted: showCompleted, feedback: $feedback)
        case .buy: MarketListContent()
        case .vault: VaultList(showCompleted: showCompleted, expanded: $expanded, feedback: $feedback)
        }
    }
}

// MARK: - Shared pieces

/// Sync/error banners at the top of every segment.
private struct StatusSection: View {
    @EnvironmentObject var store: DashboardStore
    var body: some View {
        if store.todoPendingCount + store.pendingCount + store.marketPendingCount > 0 || store.lastError != nil {
            Section {
                let n = store.todoPendingCount + store.pendingCount + store.marketPendingCount
                if n > 0 {
                    PendingSyncBadge(count: n)
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
}

/// A section of to-do rows with the standard swipes: trailing = done/undo,
/// leading = defer (one-offs only — a routine has nothing to defer).
private struct TodoSectionView: View {
    @EnvironmentObject var store: DashboardStore
    let title: String
    var tint: Color = .secondary
    var countLabel: String? = nil
    let items: [TodoItem]
    @Binding var feedback: Int

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    TodoRow(item: item) { toggle(item) }
                        .listRowInsets(EdgeInsets())
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { toggle(item) } label: {
                                Label(item.isDone() ? "Undo" : "Done",
                                      systemImage: item.isDone() ? "arrow.uturn.backward" : "checkmark")
                            }
                            .tint(item.isDone() ? .orange : .green)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if item.recur == nil {
                                Button {
                                    store.postponeTodo(item)
                                    feedback += 1
                                } label: {
                                    Label("Tomorrow", systemImage: "calendar.badge.clock")
                                }
                                .tint(.indigo)
                            }
                        }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer()
                    Text(countLabel ?? "\(items.count)").monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .padding(.top, 14)
                .padding(.bottom, 7)
                .textCase(nil)
            }
        }
    }

    private func toggle(_ item: TodoItem) {
        store.setTodoDone(item, done: !item.isDone())
        feedback += 1
    }
}

/// The add bar under every writable segment: one field, an optional date
/// (and time) — the markers that drive the phone's reminders.
private struct TodoAddBar: View {
    let placeholder: String
    let section: TodoSection
    /// Preselected due date (Today segment → today); nil = no date until chosen.
    let defaultDue: Date?
    let onAdd: (String, Date?, (hour: Int, minute: Int)?, TodoRecur?) -> Void

    @State private var text = ""
    @State private var dateOn = false
    @State private var due = Date()
    @State private var timeOn = false
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var recur: TodoRecur? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if dateOn || section == .routine {
                HStack(spacing: 12) {
                    if section == .routine {
                        Picker("Repeats", selection: $recur) {
                            Text("Daily").tag(TodoRecur?.some(.daily))
                            Text("Weekly").tag(TodoRecur?.some(.weekly))
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                    } else {
                        DatePicker("", selection: $due, displayedComponents: .date)
                            .labelsHidden()
                        Toggle(isOn: $timeOn) { Image(systemName: "clock") }
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                        if timeOn {
                            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                if section != .routine {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { dateOn.toggle() }
                    } label: {
                        Image(systemName: dateOn ? "calendar.badge.checkmark" : "calendar")
                    }
                    .foregroundStyle(dateOn ? Color.accentColor : Color.secondary)
                }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: add).fontWeight(.semibold)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .onAppear {
            if let defaultDue { due = defaultDue; dateOn = true }
            if section == .routine, recur == nil { recur = .daily }
        }
    }

    private func add() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let t: (hour: Int, minute: Int)? = (dateOn && timeOn) ? (comps.hour ?? 9, comps.minute ?? 0) : nil
        onAdd(trimmed, dateOn && section != .routine ? due : nil, t, section == .routine ? recur : nil)
        text = ""
    }
}

// MARK: - Today

private struct TodayList: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var queue: CaptureQueue
    let showCompleted: Bool
    @Binding var nudgeSent: Bool
    @Binding var feedback: Int
    @State private var addingRoutine = false

    private var board: Dashboard? { store.dashboard }
    private var items: [TodoItem] { board?.todo ?? [] }
    private var routines: [TodoItem] { items.filter { $0.recur == .daily } }
    private var overdue: [TodoItem] { visible(items.filter { $0.recur == nil && isOverdue($0) }) }
    private var dueToday: [TodoItem] { visible(items.filter { $0.recur == nil && $0.bucket() == .today }) }
    private var routineDone: Int { routines.filter { $0.isDone() }.count }

    var body: some View {
        List {
            StatusSection()

            if let rocky = board?.rocky {
                Section {
                    RockyCard(nudge: rocky, onTap: rockyTapAction(for: rocky))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } footer: {
                    if nudgeSent { Text("Queued — Rocky will handle it in your next session.") }
                }
            }

            TodoSectionView(title: "Routines", tint: .secondary,
                            countLabel: "\(routineDone)/\(routines.count)",
                            items: sortedRoutines(routines), feedback: $feedback)
            TodoSectionView(title: "Overdue", tint: .orange, items: overdue, feedback: $feedback)
            TodoSectionView(title: "Today", items: dueToday, feedback: $feedback)

            if let agenda = board?.agenda, !agenda.isEmpty {
                Section {
                    ForEach(agenda) { item in
                        AgendaRow(item: item).listRowInsets(EdgeInsets())
                    }
                } header: {
                    SectionHeader(title: "Up next").textCase(nil)
                }
            }

            if routines.isEmpty && overdue.isEmpty && dueToday.isEmpty {
                Section {
                    DashboardPlaceholder(icon: "sun.max",
                                         title: "Nothing on your list today",
                                         message: "Add a to-do below, or a daily routine from the ⋯ menu. The vault note is Areas/To-Do.md.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                Button {
                    withAnimation { addingRoutine.toggle() }
                } label: {
                    Label(addingRoutine ? "Adding a routine…" : "Add a routine",
                          systemImage: "repeat")
                        .font(.subheadline)
                }
                .listRowBackground(Color.clear)
            }

            BuiltFooter()
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: feedback)
        .safeAreaInset(edge: .bottom) {
            if addingRoutine {
                TodoAddBar(placeholder: "New routine", section: .routine, defaultDue: nil) { text, _, _, recur in
                    store.addTodo(text, section: .routine, recur: recur ?? .daily)
                    feedback += 1
                    addingRoutine = false
                }
            } else {
                TodoAddBar(placeholder: "Add a to-do for today", section: .todo, defaultDue: Date()) { text, due, time, _ in
                    store.addTodo(text, section: .todo, due: due, time: time)
                    feedback += 1
                }
            }
        }
    }

    private func isOverdue(_ item: TodoItem) -> Bool {
        if case .overdue = item.bucket() { return true }
        return false
    }

    private func visible(_ list: [TodoItem]) -> [TodoItem] {
        showCompleted ? list : list.filter { !$0.isDone() }
    }

    /// Open routines first; ticked ones sink but stay visible — a routine list
    /// that vanishes as you complete it loses the "3 of 5 done" feeling.
    private func sortedRoutines(_ list: [TodoItem]) -> [TodoItem] {
        list.sorted { a, b in
            if a.isDone() != b.isDone() { return !a.isDone() }
            return a.line < b.line
        }
    }

    private func rockyTapAction(for nudge: RockyNudge) -> (() -> Void)? {
        switch nudge.kind {
        case "review-overdue", "inbox-unprocessed":
            return {
                queue.enqueue("Rocky nudge tapped in the app — please handle now: \(nudge.message)")
                nudgeSent = true
                feedback += 1
            }
        default:
            return nil
        }
    }
}

// MARK: - Week

private struct WeekList: View {
    @EnvironmentObject var store: DashboardStore
    let showCompleted: Bool
    @Binding var feedback: Int

    private var items: [TodoItem] { store.dashboard?.todo ?? [] }
    private var weekly: [TodoItem] { items.filter { $0.recur == .weekly } }
    private var oneOffs: [TodoItem] { items.filter { $0.recur == nil && $0.section != .errand } }
    private var thisWeek: [TodoItem] {
        visible(oneOffs.filter { [.today, .thisWeek].contains($0.bucket()) || isOverdue($0) })
            .sorted { ($0.due ?? "") < ($1.due ?? "") }
    }
    private var anytime: [TodoItem] { visible(oneOffs.filter { $0.bucket() == .anytime }) }
    private var later: [TodoItem] { visible(oneOffs.filter { $0.bucket() == .later }).sorted { ($0.due ?? "") < ($1.due ?? "") } }
    private var weeklyDone: Int { weekly.filter { $0.isDone() }.count }

    var body: some View {
        List {
            StatusSection()
            TodoSectionView(title: "Weekly routines", countLabel: "\(weeklyDone)/\(weekly.count)",
                            items: weekly.sorted { !$0.isDone() && $1.isDone() }, feedback: $feedback)
            TodoSectionView(title: "This week", items: thisWeek, feedback: $feedback)
            TodoSectionView(title: "Anytime", items: anytime, feedback: $feedback)
            TodoSectionView(title: "Later", items: later, feedback: $feedback)

            if weekly.isEmpty && thisWeek.isEmpty && anytime.isEmpty && later.isEmpty {
                Section {
                    DashboardPlaceholder(icon: "calendar",
                                         title: "Clear week",
                                         message: "Weekly routines (🔁 weekly) and anything dated this week show up here.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            BuiltFooter()
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: feedback)
        .safeAreaInset(edge: .bottom) {
            TodoAddBar(placeholder: "Add a to-do for this week", section: .todo, defaultDue: nil) { text, due, time, _ in
                store.addTodo(text, section: .todo, due: due, time: time)
                feedback += 1
            }
        }
    }

    private func isOverdue(_ item: TodoItem) -> Bool {
        if case .overdue = item.bucket() { return true }
        return false
    }

    private func visible(_ list: [TodoItem]) -> [TodoItem] {
        showCompleted ? list : list.filter { !$0.isDone() }
    }
}

// MARK: - Errands

private struct ErrandsList: View {
    @EnvironmentObject var store: DashboardStore
    let showCompleted: Bool
    @Binding var feedback: Int

    private var errands: [TodoItem] { (store.dashboard?.todo ?? []).filter { $0.section == .errand } }
    private var open: [TodoItem] {
        errands.filter { !$0.isDone() }.sorted { ($0.due ?? "9999") < ($1.due ?? "9999") }
    }
    private var done: [TodoItem] { errands.filter { $0.isDone() } }

    var body: some View {
        List {
            StatusSection()
            TodoSectionView(title: "Errands", items: open, feedback: $feedback)
            if showCompleted {
                TodoSectionView(title: "Done", items: done, feedback: $feedback)
            }
            if open.isEmpty {
                Section {
                    DashboardPlaceholder(icon: "figure.walk",
                                         title: "No errands",
                                         message: "Post office, bank, pharmacy — anything that needs a trip. Add a date and it'll remind you.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            BuiltFooter()
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: feedback)
        .safeAreaInset(edge: .bottom) {
            TodoAddBar(placeholder: "Add an errand", section: .errand, defaultDue: nil) { text, due, time, _ in
                store.addTodo(text, section: .errand, due: due, time: time)
                feedback += 1
            }
        }
    }
}

// MARK: - Vault (the Daily-note tasks, trimmed)

private struct VaultList: View {
    @EnvironmentObject var store: DashboardStore
    let showCompleted: Bool
    @Binding var expanded: Set<String>
    @Binding var feedback: Int

    private var board: Dashboard? { store.dashboard }

    var body: some View {
        List {
            StatusSection()
            section(.overdue, tint: .orange)
            section(.today, tint: .secondary)
            section(.upcoming, tint: .secondary)

            if visible(.overdue).isEmpty && visible(.today).isEmpty && visible(.upcoming).isEmpty {
                Section {
                    DashboardPlaceholder(icon: "checkmark.circle",
                                         title: "Vault is clear",
                                         message: showCompleted
                                            ? "No tasks in the Daily note right now."
                                            : "Nothing open. Turn on “Show completed” to see the rest.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                Text("These are the work tasks Claude keeps in the Daily note. Tap a line to read the whole thing.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            BuiltFooter()
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: feedback)
    }

    private func visible(_ bucket: TaskBucket) -> [DashboardTask] {
        let all = board?.tasks(in: bucket) ?? []
        return showCompleted ? all : all.filter { !$0.done }
    }

    @ViewBuilder
    private func section(_ bucket: TaskBucket, tint: Color) -> some View {
        let tasks = visible(bucket)
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    VaultTaskRow(task: task, expanded: expanded.contains(task.id)) {
                        store.setDone(task, done: !task.done)
                        feedback += 1
                    }
                    .listRowInsets(EdgeInsets())
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) {
                            if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            store.setDone(task, done: !task.done)
                            feedback += 1
                        } label: {
                            Label(task.done ? "Reopen" : "Done",
                                  systemImage: task.done ? "arrow.uturn.backward" : "checkmark")
                        }
                        .tint(task.done ? .orange : .green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            store.postpone(task)
                            feedback += 1
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
}

private struct BuiltFooter: View {
    @EnvironmentObject var store: DashboardStore
    var body: some View {
        if let generated = store.dashboard?.generatedAt {
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
    TodoView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
        .environmentObject(CaptureQueue())
        .environmentObject(PushController.shared)
}
