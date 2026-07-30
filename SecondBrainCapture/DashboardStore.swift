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

    /// Supplies a configured service, or nil when there's no token yet.
    var serviceProvider: () -> GitHubService? = { nil }
    /// Repo-relative path of the generated dashboard.
    var dashboardPath: () -> String = { "dashboard.json" }

    private let monitor = NWPathMonitor()
    private let cacheURL: URL
    private let queueURL: URL
    private var isFlushing = false
    /// How long a cached dashboard stays good enough to skip a network round-trip.
    private let staleAfter: TimeInterval = 5 * 60

    var pendingCount: Int { pending.count }
    var hasLoaded: Bool { dashboard != nil }

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("dashboard-cache.json")
        queueURL = dir.appendingPathComponent("task-actions.json")
        loadCache()
        loadQueue()

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flush() }
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
            return
        }
        await refresh()
        await flush()
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
}
