import Foundation
import Network

/// A task edit that hasn't reached GitHub yet.
///
/// Check-offs get the same treatment as captures: the change is applied locally
/// and persisted to disk first, then synced. Tapping a checkbox on the metro
/// must feel exactly as final as tapping it at a desk.
struct PendingTaskAction: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case setDone(Bool)
        case postpone(String)   // yyyy-MM-dd
    }

    let id: UUID
    let taskID: String
    let file: String
    let line: Int
    let raw: String
    let text: String
    let kind: Kind
    let createdAt: Date

    init(taskID: String, file: String, line: Int, raw: String, text: String, kind: Kind) {
        self.id = UUID()
        self.taskID = taskID
        self.file = file
        self.line = line
        self.raw = raw
        self.text = text
        self.kind = kind
        self.createdAt = Date()
    }

    var commitMessage: String {
        let short = text.prefix(60)
        switch kind {
        case .setDone(let done): return "mobile: \(done ? "complete" : "reopen") \(short)"
        case .postpone(let day): return "mobile: defer \(short) → \(day)"
        }
    }
}

/// A market-list edit that hasn't reached GitHub yet. Simpler than
/// `PendingTaskAction` — no buckets or due dates, and `.add` is a write kind
/// tasks never need, since every task already exists in the vault before the
/// phone can see it.
struct PendingMarketAction: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case add
        case setDone(Bool)
    }

    let id: UUID
    /// The item's `MarketItem.id` — a real `stable_id` once CI has scraped it,
    /// or this action's own UUID string for an item the phone just added and
    /// no dashboard refresh has assigned a canonical id to yet.
    let itemID: String
    let file: String
    let line: Int
    let raw: String
    let text: String
    let kind: Kind
    let createdAt: Date

    init(itemID: String, file: String, line: Int, raw: String, text: String, kind: Kind) {
        self.id = UUID()
        self.itemID = itemID
        self.file = file
        self.line = line
        self.raw = raw
        self.text = text
        self.kind = kind
        self.createdAt = Date()
    }

    var commitMessage: String {
        let short = text.prefix(60)
        switch kind {
        case .add: return "mobile: add to market list — \(short)"
        case .setDone(let done): return "mobile: \(done ? "check off" : "uncheck") \(short)"
        }
    }
}

/// A To-Do list edit that hasn't reached GitHub yet. Three write kinds: add
/// (insert under a section heading), done (checkbox for one-offs, ✅ stamp for
/// routines — decided at flush time from `recur`) and postpone.
struct PendingTodoAction: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case add(TodoSection)
        case setDone(Bool)
        case postpone(String)   // yyyy-MM-dd
    }

    let id: UUID
    let itemID: String
    let file: String
    let line: Int
    let raw: String
    let text: String
    let recur: TodoRecur?
    let kind: Kind
    let createdAt: Date

    init(itemID: String, file: String, line: Int, raw: String, text: String, recur: TodoRecur?, kind: Kind) {
        self.id = UUID()
        self.itemID = itemID
        self.file = file
        self.line = line
        self.raw = raw
        self.text = text
        self.recur = recur
        self.kind = kind
        self.createdAt = Date()
    }

    var commitMessage: String {
        let short = text.prefix(60)
        switch kind {
        case .add(let section): return "mobile: add \(section.rawValue) — \(short)"
        case .setDone(let done): return "mobile: \(done ? "done" : "undo") \(short)"
        case .postpone(let day): return "mobile: defer \(short) → \(day)"
        }
    }
}

/// A Health quick-log entry that hasn't reached GitHub yet. Simpler still than
/// market's — always an append, never a toggle, and never collapsed with a
/// sibling, since each tap is its own plain-text moment ("logged plainly, no
/// lecturing" — every tap is a distinct fact, not a value to overwrite).
struct PendingHealthAction: Codable, Identifiable, Equatable {
    let id: UUID
    let file: String
    let text: String
    let createdAt: Date

    init(file: String, text: String) {
        self.id = UUID()
        self.file = file
        self.text = text
        self.createdAt = Date()
    }

    var commitMessage: String { "mobile: health log — \(text.prefix(60))" }
}

/// A Pocket "Important" edit that hasn't reached GitHub yet. Three write
/// kinds: add (insert under `## Important`), edit (replace one bullet's text)
/// and delete (drop the bullet's line). Facts are plain bullets, never
/// checkboxes, so there is no done/postpone here.
struct PendingFactAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, Equatable { case add, edit, delete }

    let id: UUID
    /// `PocketFact.id` — a hash of the text once CI has indexed the line, or
    /// this action's own UUID string for a fact the phone just added.
    let factID: String
    let file: String
    let line: Int
    /// `.add`: the line to write. `.edit`/`.delete`: the line the vault holds
    /// *now* (what `locate` looks for), kept from the oldest collapsed action.
    let raw: String
    /// The new label/detail (`.add`, `.edit`); the shown ones for `.delete`.
    let label: String
    let detail: String
    let kind: Kind
    let createdAt: Date

    init(factID: String, file: String, line: Int, raw: String, label: String, detail: String, kind: Kind) {
        self.id = UUID()
        self.factID = factID
        self.file = file
        self.line = line
        self.raw = raw
        self.label = label
        self.detail = detail
        self.kind = kind
        self.createdAt = Date()
    }

    var commitMessage: String {
        let short = label.prefix(60)
        switch kind {
        case .add: return "mobile: add important — \(short)"
        case .edit: return "mobile: edit important — \(short)"
        case .delete: return "mobile: remove important — \(short)"
        }
    }
}

/// Owns the read side of the vault: fetches the prebuilt `dashboard.json`,
/// caches it so the app opens instantly (and works on the underground), and
/// queues task edits back to GitHub.
@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var pending: [PendingTaskAction] = []
    @Published private(set) var marketPending: [PendingMarketAction] = []
    @Published private(set) var healthPending: [PendingHealthAction] = []
    @Published private(set) var todoPending: [PendingTodoAction] = []
    @Published private(set) var factPending: [PendingFactAction] = []

    /// Supplies a configured service, or nil when there's no token yet.
    var serviceProvider: () -> GitHubService? = { nil }
    /// Repo-relative path of the generated dashboard.
    var dashboardPath: () -> String = { "dashboard.json" }
    /// Repo-relative path of the market list note.
    var marketListPath: () -> String = { "Areas/Market-List.md" }
    /// Repo-relative path of the To-Do list note.
    var todoListPath: () -> String = { "Areas/To-Do.md" }
    /// Fallback path of the Pocket note when the dashboard doesn't name it.
    var pocketNotePath: () -> String = { "Areas/Pocket.md" }
    /// Repo-relative path of *today's* daily note — the Health log's home.
    var todayNotePath: () -> String = { "Daily/\(DateFormatter.vaultDay.string(from: Date())).md" }

    private let monitor = NWPathMonitor()
    private let cacheURL: URL
    private let queueURL: URL
    private let marketQueueURL: URL
    private let healthQueueURL: URL
    private let todoQueueURL: URL
    private let factQueueURL: URL
    private var isFlushing = false
    private var isFlushingMarket = false
    private var isFlushingHealth = false
    private var isFlushingTodo = false
    private var isFlushingFacts = false
    /// The fact action whose network call is in flight — never collapsed into,
    /// since the vault is about to change under it.
    private var factInFlight: UUID?
    /// Fact actions that committed within the last few minutes. `dashboard.json`
    /// only catches up when CI rebuilds it, so a refresh in that window would
    /// otherwise bring the old list back.
    private var factRecent: [(action: PendingFactAction, at: Date)] = []
    private let factRecentTTL: TimeInterval = 5 * 60
    /// How long a cached dashboard stays good enough to skip a network round-trip.
    private let staleAfter: TimeInterval = 5 * 60

    var pendingCount: Int { pending.count }
    var marketPendingCount: Int { marketPending.count }
    var healthPendingCount: Int { healthPending.count }
    var todoPendingCount: Int { todoPending.count }
    var factPendingCount: Int { factPending.count }
    var hasLoaded: Bool { dashboard != nil }

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("dashboard-cache.json")
        queueURL = dir.appendingPathComponent("task-actions.json")
        marketQueueURL = dir.appendingPathComponent("market-actions.json")
        healthQueueURL = dir.appendingPathComponent("health-actions.json")
        todoQueueURL = dir.appendingPathComponent("todo-actions.json")
        factQueueURL = dir.appendingPathComponent("fact-actions.json")
        loadCache()
        loadQueue()
        loadMarketQueue()
        loadHealthQueue()
        loadTodoQueue()
        loadFactQueue()

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                await self?.flush()
                await self?.flushMarket()
                await self?.flushHealth()
                await self?.flushTodo()
                await self?.flushFacts()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.alp.SecondBrainCapture.dashboard"))
    }

    // MARK: - Reading

    /// Pull a fresh dashboard. Failures are surfaced but never clear the cached
    /// copy — a stale board beats a blank one.
    func refresh() async {
        guard !isRefreshing, let service = serviceProvider() else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var fresh = try await service.fetchDashboard(path: dashboardPath())
            // A refresh must not visually undo an edit that hasn't synced yet.
            fresh.tasks = applyPending(to: fresh.tasks)
            fresh.market = applyPendingMarket(to: fresh.market)
            fresh.health = applyPendingHealth(to: fresh.health)
            fresh.todo = applyPendingTodo(to: fresh.todo)
            fresh.pocketFacts = applyPendingFacts(to: fresh.pocketFacts)
            dashboard = fresh
            lastLoaded = Date()
            lastError = nil
            saveCache(fresh)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Refresh only if the cache has gone stale — used on launch and foreground
    /// so switching tabs doesn't hammer the API.
    func refreshIfStale() async {
        if let lastLoaded, Date().timeIntervalSince(lastLoaded) < staleAfter, dashboard != nil {
            await flush()
            await flushMarket()
            await flushHealth()
            await flushTodo()
            await flushFacts()
            return
        }
        await refresh()
        await flush()
        await flushMarket()
        await flushHealth()
        await flushTodo()
        await flushFacts()
    }

    // MARK: - Writing

    func setDone(_ task: DashboardTask, done: Bool) {
        mutate(taskID: task.id) { current in
            DashboardTask(id: current.id, text: current.text, done: done, bucket: current.bucket,
                          due: current.due, overdueDays: current.overdueDays, project: current.project,
                          file: current.file, line: current.line, raw: current.raw)
        }
        enqueue(PendingTaskAction(taskID: task.id, file: task.file, line: task.line,
                                  raw: task.raw, text: task.text, kind: .setDone(done)))
    }

    /// Push a task's due date out. Defaults to tomorrow — the overwhelmingly
    /// common case, and the only one a swipe gesture can express.
    func postpone(_ task: DashboardTask, to date: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) {
        let day = DateFormatter.vaultDay.string(from: date)
        mutate(taskID: task.id) { current in
            DashboardTask(id: current.id, text: current.text, done: current.done, bucket: .upcoming,
                          due: day, overdueDays: 0, project: current.project,
                          file: current.file, line: current.line, raw: current.raw)
        }
        enqueue(PendingTaskAction(taskID: task.id, file: task.file, line: task.line,
                                  raw: task.raw, text: task.text, kind: .postpone(day)))
    }

    /// Drain queued edits in order, stopping at the first failure so a transient
    /// error doesn't reorder or drop later edits.
    @discardableResult
    func flush() async -> Bool {
        guard !isFlushing, !pending.isEmpty, let service = serviceProvider() else {
            return pending.isEmpty
        }
        isFlushing = true
        defer { isFlushing = false }

        while let action = pending.first {
            do {
                try await service.editLine(path: action.file,
                                           lineNumber: action.line,
                                           expectedLine: action.raw,
                                           message: action.commitMessage) { line in
                    switch action.kind {
                    case .setDone(let done): return TaskLineEditor.setDone(line, done: done)
                    case .postpone(let day):
                        guard let date = DateFormatter.vaultDay.date(from: day) else { return line }
                        return TaskLineEditor.setDue(line, to: date)
                    }
                }
                pending.removeFirst()
                saveQueue()
                lastError = nil
            } catch GitHubError.badResponse(let code, let msg) where code == 422 {
                // The line is gone — the note was rewritten under us. Retrying
                // forever would wedge the queue, so drop it and say why.
                pending.removeFirst()
                saveQueue()
                lastError = msg
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        return true
    }

    // MARK: - Writing (market list)

    /// Add an item, optimistically and offline-first — same feel as tapping a
    /// task checkbox. The item shows up with a temp id until either this
    /// action's own commit lands (it stays visible, just re-injected on the
    /// next refresh — see `applyPendingMarket`) or CI reindexes the vault and
    /// hands it a real one.
    func addMarketItem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = marketListPath()
        let raw = "- [ ] \(trimmed)"
        let tempID = UUID().uuidString
        let item = MarketItem(id: tempID, text: trimmed, done: false, file: path, line: 0, raw: raw)

        if var board = dashboard {
            board.market.append(item)
            dashboard = board
            saveCache(board)
        }
        enqueueMarket(PendingMarketAction(itemID: tempID, file: path, line: 0, raw: raw,
                                          text: trimmed, kind: .add))
    }

    func setMarketDone(_ item: MarketItem, done: Bool) {
        mutateMarket(itemID: item.id) { current in
            MarketItem(id: current.id, text: current.text, done: done,
                      file: current.file, line: current.line, raw: current.raw)
        }
        enqueueMarket(PendingMarketAction(itemID: item.id, file: item.file, line: item.line,
                                          raw: item.raw, text: item.text, kind: .setDone(done)))
    }

    /// Same ordered drain as `flush()`, kept as its own queue: market edits and
    /// task edits touch different files and shouldn't block on each other.
    @discardableResult
    func flushMarket() async -> Bool {
        guard !isFlushingMarket, !marketPending.isEmpty, let service = serviceProvider() else {
            return marketPending.isEmpty
        }
        isFlushingMarket = true
        defer { isFlushingMarket = false }

        while let action = marketPending.first {
            do {
                switch action.kind {
                case .add:
                    try await service.appendLine(path: action.file, line: action.raw,
                                                 message: action.commitMessage)
                case .setDone:
                    try await service.editLine(path: action.file, lineNumber: action.line,
                                               expectedLine: action.raw,
                                               message: action.commitMessage) { line in
                        guard case .setDone(let done) = action.kind else { return line }
                        return TaskLineEditor.setDone(line, done: done)
                    }
                }
                marketPending.removeFirst()
                saveMarketQueue()
                lastError = nil
            } catch GitHubError.badResponse(let code, let msg) where code == 422 {
                marketPending.removeFirst()
                saveMarketQueue()
                lastError = msg
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        return true
    }

    // MARK: - Writing (health log)

    /// Log one plain fact ("🚬", "⚡ energy drink", or a free-text note) to
    /// today's daily note. Optimistic and offline-first like every other write
    /// here, but there's nothing to toggle or undo — logging is append-only.
    func logHealth(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = todayNotePath()

        if var board = dashboard {
            board.health = HealthToday(loggedToday: board.health.loggedToday + [trimmed])
            dashboard = board
            saveCache(board)
        }
        healthPending.append(PendingHealthAction(file: path, text: trimmed))
        saveHealthQueue()
        Task { await flushHealth() }
    }

    /// Drained in order like the other queues, but never blocked on a specific
    /// line — each entry is an independent append, so a stale line number can
    /// never apply.
    @discardableResult
    func flushHealth() async -> Bool {
        guard !isFlushingHealth, !healthPending.isEmpty, let service = serviceProvider() else {
            return healthPending.isEmpty
        }
        isFlushingHealth = true
        defer { isFlushingHealth = false }

        while let action = healthPending.first {
            do {
                try await service.appendHealthBullet(path: action.file, text: action.text,
                                                     message: action.commitMessage)
                healthPending.removeFirst()
                saveHealthQueue()
                lastError = nil
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        return true
    }

    // MARK: - Writing (to-do list)

    /// Add an item under a section, optimistically and offline-first like the
    /// market list. `due`/`time` become `📅`/`⏰` markers on the line — the
    /// same markers the vault (and the phone's reminders) already understand.
    func addTodo(_ text: String, section: TodoSection, due: Date? = nil,
                 time: (hour: Int, minute: Int)? = nil, recur: TodoRecur? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = todoListPath()
        let raw = TodoLineEditor.newLine(text: trimmed, due: due, time: time, recur: recur)
        let tempID = UUID().uuidString
        let item = TodoItem(id: tempID, text: trimmed, section: section, recur: recur, done: false,
                            due: due.map { DateFormatter.vaultDay.string(from: $0) },
                            time: time.map { String(format: "%02d:%02d", $0.hour, $0.minute) },
                            file: path, line: 0, raw: raw)

        if var board = dashboard {
            board.todo.append(item)
            dashboard = board
            saveCache(board)
        }
        enqueueTodo(PendingTodoAction(itemID: tempID, file: path, line: 0, raw: raw,
                                      text: trimmed, recur: recur, kind: .add(section)))
    }

    /// Tick or untick. For a routine this stamps/unstamps `✅ today` and the
    /// checkbox is left alone; for a one-off it flips the checkbox.
    func setTodoDone(_ item: TodoItem, done: Bool) {
        let today = DateFormatter.vaultDay.string(from: Date())
        mutateTodo(itemID: item.id) { current in
            var next = current
            if current.recur != nil {
                next.lastDone = done ? today : nil
                next.raw = TodoLineEditor.setDoneStamp(current.raw, date: done ? Date() : nil)
            } else {
                next.done = done
                next.raw = TaskLineEditor.setDone(current.raw, done: done)
            }
            return next
        }
        enqueueTodo(PendingTodoAction(itemID: item.id, file: item.file, line: item.line, raw: item.raw,
                                      text: item.text, recur: item.recur, kind: .setDone(done)))
    }

    /// Push a one-off's due date out (default: tomorrow).
    func postponeTodo(_ item: TodoItem, to date: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) {
        guard item.recur == nil else { return }
        let day = DateFormatter.vaultDay.string(from: date)
        mutateTodo(itemID: item.id) { current in
            var next = current
            next.due = day
            next.raw = TaskLineEditor.setDue(current.raw, to: date)
            return next
        }
        enqueueTodo(PendingTodoAction(itemID: item.id, file: item.file, line: item.line, raw: item.raw,
                                      text: item.text, recur: item.recur, kind: .postpone(day)))
    }

    @discardableResult
    func flushTodo() async -> Bool {
        guard !isFlushingTodo, !todoPending.isEmpty, let service = serviceProvider() else {
            return todoPending.isEmpty
        }
        isFlushingTodo = true
        defer { isFlushingTodo = false }

        while let action = todoPending.first {
            do {
                switch action.kind {
                case .add(let section):
                    try await service.insertLine(path: action.file, underHeading: section.heading,
                                                 line: action.raw, message: action.commitMessage)
                case .setDone(let done):
                    try await service.editLine(path: action.file, lineNumber: action.line,
                                               expectedLine: action.raw,
                                               message: action.commitMessage) { line in
                        action.recur != nil
                            ? TodoLineEditor.setDoneStamp(line, date: done ? action.createdAt : nil)
                            : TaskLineEditor.setDone(line, done: done)
                    }
                case .postpone(let day):
                    try await service.editLine(path: action.file, lineNumber: action.line,
                                               expectedLine: action.raw,
                                               message: action.commitMessage) { line in
                        guard let date = DateFormatter.vaultDay.date(from: day) else { return line }
                        return TaskLineEditor.setDue(line, to: date)
                    }
                }
                todoPending.removeFirst()
                saveTodoQueue()
                lastError = nil
            } catch GitHubError.badResponse(let code, let msg) where code == 422 {
                todoPending.removeFirst()
                saveTodoQueue()
                lastError = msg
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        return true
    }

    // MARK: - Writing (Pocket "Important")

    private var factsPath: String {
        if let file = dashboard?.pocketFile, !file.isEmpty { return file }
        return pocketNotePath()
    }

    /// Add a fact from one line of text — `label — detail`, detail optional.
    func addFact(_ text: String) {
        let parts = FactEditor.split(FactEditor.clean(text))
        addFact(label: parts.label, detail: parts.detail)
    }

    /// Add a fact, optimistically and offline-first. It shows up under a temp id
    /// until CI re-indexes the vault and hands it a real one.
    func addFact(label: String, detail: String = "") {
        let l = FactEditor.cleanLabel(label), d = FactEditor.clean(detail)
        guard !l.isEmpty else { return }
        let path = factsPath
        let tempID = UUID().uuidString
        let raw = FactEditor.newLine(label: l, detail: d)

        mutateFacts { $0.append(PocketFact(id: tempID, label: l, detail: d, file: path, line: 0, raw: raw)) }
        enqueueFact(PendingFactAction(factID: tempID, file: path, line: 0, raw: raw,
                                      label: l, detail: d, kind: .add))
    }

    /// Replace a fact's text. The optimistic copy keeps the old `id` (a hash of
    /// the old text) so further edits still find it until CI re-issues the list.
    func editFact(_ fact: PocketFact, label: String, detail: String) {
        let l = FactEditor.cleanLabel(label), d = FactEditor.clean(detail)
        guard !l.isEmpty, l != fact.label || d != fact.detail else { return }
        let path = fact.file.isEmpty ? factsPath : fact.file
        let newRaw = FactEditor.replaced(line: fact.raw, label: l, detail: d)

        mutateFacts { facts in
            guard let i = facts.firstIndex(where: { $0.id == fact.id }) else { return }
            facts[i] = PocketFact(id: fact.id, label: l, detail: d, file: facts[i].file,
                                  line: facts[i].line, raw: newRaw)
        }
        enqueueFact(PendingFactAction(factID: fact.id, file: path, line: fact.line, raw: fact.raw,
                                      label: l, detail: d, kind: .edit))
    }

    func deleteFact(_ fact: PocketFact) {
        let path = fact.file.isEmpty ? factsPath : fact.file
        mutateFacts { $0.removeAll { $0.id == fact.id } }
        enqueueFact(PendingFactAction(factID: fact.id, file: path, line: fact.line, raw: fact.raw,
                                      label: fact.label, detail: fact.detail, kind: .delete))
    }

    /// Same ordered drain as the other queues. A 422 means the line is gone
    /// (or the note was rewritten) — retrying would wedge the queue, so the
    /// action is dropped and the reason shown.
    @discardableResult
    func flushFacts() async -> Bool {
        guard !isFlushingFacts, !factPending.isEmpty, let service = serviceProvider() else {
            return factPending.isEmpty
        }
        isFlushingFacts = true
        defer { isFlushingFacts = false; factInFlight = nil }

        while let action = factPending.first {
            factInFlight = action.id
            do {
                switch action.kind {
                case .add:
                    try await service.insertLine(path: action.file, underHeading: FactEditor.heading,
                                                 line: action.raw, message: action.commitMessage,
                                                 before: FactEditor.cardsAnchor,
                                                 template: FactEditor.template)
                case .edit:
                    try await service.editLine(path: action.file, lineNumber: action.line,
                                               expectedLine: action.raw,
                                               message: action.commitMessage) { line in
                        FactEditor.replaced(line: line, label: action.label, detail: action.detail)
                    }
                case .delete:
                    try await service.removeLine(path: action.file, lineNumber: action.line,
                                                 expectedLine: action.raw, message: action.commitMessage)
                }
                factInFlight = nil
                factPending.removeAll { $0.id == action.id }
                factRecent.append((action, Date()))
                saveFactQueue()
                lastError = nil
            } catch GitHubError.badResponse(let code, let msg) where code == 422 {
                factInFlight = nil
                factPending.removeAll { $0.id == action.id }
                saveFactQueue()
                lastError = msg
            } catch {
                factInFlight = nil
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        return true
    }

    // MARK: - Internals

    private func enqueue(_ action: PendingTaskAction) {
        // Collapse repeated edits to the same task — tapping a checkbox twice
        // should end as one commit, not two fighting each other.
        pending.removeAll { $0.taskID == action.taskID && sameKindFamily($0.kind, action.kind) }
        pending.append(action)
        saveQueue()
        Task { await flush() }
    }

    private func sameKindFamily(_ a: PendingTaskAction.Kind, _ b: PendingTaskAction.Kind) -> Bool {
        switch (a, b) {
        case (.setDone, .setDone), (.postpone, .postpone): return true
        default: return false
        }
    }

    private func mutate(taskID: String, _ transform: (DashboardTask) -> DashboardTask) {
        guard var board = dashboard,
              let index = board.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        board.tasks[index] = transform(board.tasks[index])
        dashboard = board
        saveCache(board)
    }

    /// Replay unsynced edits over a freshly fetched task list.
    private func applyPending(to tasks: [DashboardTask]) -> [DashboardTask] {
        guard !pending.isEmpty else { return tasks }
        var result = tasks
        for action in pending {
            guard let index = result.firstIndex(where: { $0.id == action.taskID }) else { continue }
            let t = result[index]
            switch action.kind {
            case .setDone(let done):
                result[index] = DashboardTask(id: t.id, text: t.text, done: done, bucket: t.bucket,
                                              due: t.due, overdueDays: t.overdueDays, project: t.project,
                                              file: t.file, line: t.line, raw: t.raw)
            case .postpone(let day):
                result[index] = DashboardTask(id: t.id, text: t.text, done: t.done, bucket: .upcoming,
                                              due: day, overdueDays: 0, project: t.project,
                                              file: t.file, line: t.line, raw: t.raw)
            }
        }
        return result
    }

    private func enqueueMarket(_ action: PendingMarketAction) {
        // Collapse repeated toggles of the same item, exactly like tasks — but
        // never collapse across kinds: an `.add` must survive until it commits,
        // even if a `.setDone` for the same item is queued right behind it.
        marketPending.removeAll { $0.itemID == action.itemID && sameMarketKindFamily($0.kind, action.kind) }
        marketPending.append(action)
        saveMarketQueue()
        Task { await flushMarket() }
    }

    private func sameMarketKindFamily(_ a: PendingMarketAction.Kind, _ b: PendingMarketAction.Kind) -> Bool {
        switch (a, b) {
        case (.add, .add), (.setDone, .setDone): return true
        default: return false
        }
    }

    private func mutateMarket(itemID: String, _ transform: (MarketItem) -> MarketItem) {
        guard var board = dashboard,
              let index = board.market.firstIndex(where: { $0.id == itemID }) else { return }
        board.market[index] = transform(board.market[index])
        dashboard = board
        saveCache(board)
    }

    /// Replay unsynced edits over a freshly fetched market list. Unlike tasks,
    /// a still-pending `.add` has no counterpart in `items` yet — CI hasn't
    /// reindexed the vault — so it's re-appended rather than skipped, or the
    /// item the phone just added would flicker out of view on every refresh
    /// until the next CI run.
    private func applyPendingMarket(to items: [MarketItem]) -> [MarketItem] {
        guard !marketPending.isEmpty else { return items }
        var result = items
        for action in marketPending {
            guard let index = result.firstIndex(where: { $0.id == action.itemID }) else {
                if case .add = action.kind {
                    result.append(MarketItem(id: action.itemID, text: action.text, done: false,
                                             file: action.file, line: action.line, raw: action.raw))
                }
                continue
            }
            if case .setDone(let done) = action.kind {
                let m = result[index]
                result[index] = MarketItem(id: m.id, text: m.text, done: done,
                                           file: m.file, line: m.line, raw: m.raw)
            }
        }
        return result
    }

    /// Queue a to-do edit. Repeated toggles of one item collapse into the
    /// newest, but the newest inherits the *older* action's `raw` — that's the
    /// line the vault still has, since the collapsed action never committed.
    /// Different kinds never collapse (an `.add` must survive a `.setDone`
    /// queued right behind it).
    private func enqueueTodo(_ action: PendingTodoAction) {
        var next = action
        if let older = todoPending.first(where: { $0.itemID == action.itemID && sameTodoKindFamily($0.kind, action.kind) }) {
            next = PendingTodoAction(itemID: action.itemID, file: action.file, line: older.line, raw: older.raw,
                                     text: action.text, recur: action.recur, kind: action.kind)
            todoPending.removeAll { $0.id == older.id }
        }
        todoPending.append(next)
        saveTodoQueue()
        Task { await flushTodo() }
    }

    private func sameTodoKindFamily(_ a: PendingTodoAction.Kind, _ b: PendingTodoAction.Kind) -> Bool {
        switch (a, b) {
        case (.setDone, .setDone), (.postpone, .postpone): return true
        default: return false
        }
    }

    private func mutateTodo(itemID: String, _ transform: (TodoItem) -> TodoItem) {
        guard var board = dashboard,
              let index = board.todo.firstIndex(where: { $0.id == itemID }) else { return }
        board.todo[index] = transform(board.todo[index])
        dashboard = board
        saveCache(board)
    }

    /// Replay unsynced to-do edits over a fresh list. A pending `.add` has no
    /// counterpart yet (CI hasn't reindexed) and is re-appended, like market.
    private func applyPendingTodo(to items: [TodoItem]) -> [TodoItem] {
        guard !todoPending.isEmpty else { return items }
        var result = items
        for action in todoPending {
            guard let index = result.firstIndex(where: { $0.id == action.itemID }) else {
                if case .add(let section) = action.kind {
                    // Rebuild the optimistic row from its own line (the line carries the markers).
                    let dueRange = action.raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
                    let timeRange = action.raw.range(of: #"⏰\s*\d{1,2}:\d{2}"#, options: .regularExpression)
                    result.append(TodoItem(id: action.itemID, text: action.text, section: section, recur: action.recur,
                                           done: false,
                                           due: dueRange.map { String(action.raw[$0]) },
                                           time: timeRange.map { String(action.raw[$0]).replacingOccurrences(of: "⏰", with: "").trimmingCharacters(in: .whitespaces) },
                                           file: action.file, line: 0, raw: action.raw))
                }
                continue
            }
            var t = result[index]
            switch action.kind {
            case .add: break
            case .setDone(let done):
                if t.recur != nil {
                    t.lastDone = done ? DateFormatter.vaultDay.string(from: action.createdAt) : nil
                    t.raw = TodoLineEditor.setDoneStamp(t.raw, date: done ? action.createdAt : nil)
                } else {
                    t.done = done
                    t.raw = TaskLineEditor.setDone(t.raw, done: done)
                }
            case .postpone(let day):
                t.due = day
                if let date = DateFormatter.vaultDay.date(from: day) { t.raw = TaskLineEditor.setDue(t.raw, to: date) }
            }
            result[index] = t
        }
        return result
    }

    private func mutateFacts(_ change: (inout [PocketFact]) -> Void) {
        guard var board = dashboard else { return }
        change(&board.pocketFacts)
        dashboard = board
        saveCache(board)
    }

    /// Queue a fact edit, collapsing what hasn't left the phone yet:
    /// - edit of an unsynced add → the add is rewritten, one commit with the final text;
    /// - delete of an unsynced add → both vanish, the vault never hears of it;
    /// - repeated edits → newest wins but inherits the *older* action's `raw`/`line`
    ///   (the line the vault still holds);
    /// - delete after unsynced edits → one delete of the line the vault holds.
    /// An action whose network call is in flight is never touched.
    private func enqueueFact(_ action: PendingFactAction) {
        func mine(_ kind: PendingFactAction.Kind) -> Int? {
            factPending.firstIndex { $0.factID == action.factID && $0.kind == kind && $0.id != factInFlight }
        }
        switch action.kind {
        case .add:
            factPending.append(action)
        case .edit:
            if let i = mine(.add) {
                let old = factPending[i]
                factPending[i] = PendingFactAction(factID: old.factID, file: old.file, line: 0,
                                                   raw: FactEditor.newLine(label: action.label, detail: action.detail),
                                                   label: action.label, detail: action.detail, kind: .add)
            } else if let i = mine(.edit) {
                let older = factPending.remove(at: i)
                factPending.append(PendingFactAction(factID: action.factID, file: action.file, line: older.line,
                                                     raw: older.raw, label: action.label, detail: action.detail,
                                                     kind: .edit))
            } else {
                factPending.append(action)
            }
        case .delete:
            if let i = mine(.add) {
                factPending.remove(at: i)   // never committed, nothing to delete
            } else if let i = mine(.edit) {
                let older = factPending[i]
                factPending.removeAll { $0.factID == action.factID && $0.kind == .edit && $0.id != factInFlight }
                factPending.append(PendingFactAction(factID: action.factID, file: action.file, line: older.line,
                                                     raw: older.raw, label: action.label, detail: action.detail,
                                                     kind: .delete))
            } else {
                factPending.append(action)
            }
        }
        saveFactQueue()
        Task { await flushFacts() }
    }

    /// Replay unsynced fact edits — and those that committed minutes ago, which
    /// CI hasn't reindexed yet — over a freshly fetched list, so it doesn't
    /// flicker back. Every step is idempotent: once CI has caught up the
    /// replayed add finds its text, the edit and delete find nothing to match.
    private func applyPendingFacts(to facts: [PocketFact]) -> [PocketFact] {
        factRecent.removeAll { Date().timeIntervalSince($0.at) > factRecentTTL }
        let actions = factRecent.map { (action: $0.action, recent: true) }
            + factPending.map { (action: $0, recent: false) }
        guard !actions.isEmpty else { return facts }

        var result = facts
        for (action, recent) in actions {
            let index = result.firstIndex {
                $0.id == action.factID
                    || (action.kind != .add && $0.raw.trimmingCharacters(in: .whitespaces)
                        == action.raw.trimmingCharacters(in: .whitespaces))
            }
            switch action.kind {
            case .add:
                let text = FactEditor.newLine(label: action.label, detail: action.detail)
                let landed = result.contains { $0.id == action.factID }
                    || (recent && result.contains { $0.raw.trimmingCharacters(in: .whitespaces) == text })
                if !landed {
                    result.append(PocketFact(id: action.factID, label: action.label, detail: action.detail,
                                             file: action.file, line: 0, raw: text))
                }
            case .edit:
                guard let i = index else { continue }
                let f = result[i]
                result[i] = PocketFact(id: f.id, label: action.label, detail: action.detail, file: f.file,
                                       line: f.line,
                                       raw: FactEditor.replaced(line: f.raw, label: action.label, detail: action.detail))
            case .delete:
                if let i = index { result.remove(at: i) }
            }
        }
        return result
    }

    /// Replay unsynced logs over a freshly fetched "today" list — a still-
    /// pending entry has no counterpart there yet (CI hasn't reindexed), so
    /// it's added rather than skipped, same reasoning as market's `.add`.
    private func applyPendingHealth(to health: HealthToday) -> HealthToday {
        guard !healthPending.isEmpty else { return health }
        var items = health.loggedToday
        for action in healthPending where !items.contains(action.text) {
            items.append(action.text)
        }
        return HealthToday(loggedToday: items)
    }

    // MARK: - Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let board = try? JSONDecoder().decode(Dashboard.self, from: data) else { return }
        dashboard = board
        // Deliberately leaves `lastLoaded` nil so the first foreground refresh
        // still fires — the cache is for instant paint, not for freshness.
    }

    private func saveCache(_ board: Dashboard) {
        guard let data = try? JSONEncoder().encode(board) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL),
              let items = try? JSONDecoder().decode([PendingTaskAction].self, from: data) else { return }
        pending = items
    }

    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func loadMarketQueue() {
        guard let data = try? Data(contentsOf: marketQueueURL),
              let items = try? JSONDecoder().decode([PendingMarketAction].self, from: data) else { return }
        marketPending = items
    }

    private func saveMarketQueue() {
        guard let data = try? JSONEncoder().encode(marketPending) else { return }
        try? data.write(to: marketQueueURL, options: .atomic)
    }

    private func loadHealthQueue() {
        guard let data = try? Data(contentsOf: healthQueueURL),
              let items = try? JSONDecoder().decode([PendingHealthAction].self, from: data) else { return }
        healthPending = items
    }

    private func saveHealthQueue() {
        guard let data = try? JSONEncoder().encode(healthPending) else { return }
        try? data.write(to: healthQueueURL, options: .atomic)
    }

    private func loadTodoQueue() {
        guard let data = try? Data(contentsOf: todoQueueURL),
              let items = try? JSONDecoder().decode([PendingTodoAction].self, from: data) else { return }
        todoPending = items
    }

    private func saveTodoQueue() {
        guard let data = try? JSONEncoder().encode(todoPending) else { return }
        try? data.write(to: todoQueueURL, options: .atomic)
    }

    private func loadFactQueue() {
        guard let data = try? Data(contentsOf: factQueueURL),
              let items = try? JSONDecoder().decode([PendingFactAction].self, from: data) else { return }
        factPending = items
    }

    private func saveFactQueue() {
        guard let data = try? JSONEncoder().encode(factPending) else { return }
        try? data.write(to: factQueueURL, options: .atomic)
    }
}
