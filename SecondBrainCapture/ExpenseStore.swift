import Foundation
import Network

/// Durable log of expenses recorded on this phone — the same promise as
/// `CaptureQueue`: an entry is on disk *before* any network call, so a tap in
/// a shop with no signal is never lost.
///
/// Each expense becomes one new file in the vault's
/// `Areas/Finance/expenses/inbox/`; nothing existing is edited, so there is no
/// content for the Mac to conflict with (a branch that moved mid-write is
/// simply retried). The vault folds the files into its monthly ledger
/// (`finance.py expenses fold`).
///
/// A shared instance rather than a `@StateObject` wired up in the root view's
/// `.task`: `LogExpenseIntent` runs when Shortcuts launches the app in the
/// background, where no scene (and so no `.task`) exists. For the same reason
/// the default uploader builds its own `GitHubService` from stored settings.
@MainActor
final class ExpenseStore: ObservableObject {
    static let shared = ExpenseStore()

    /// Newest first. Unsynced entries are never trimmed.
    @Published private(set) var entries: [ExpenseEntry] = []
    @Published private(set) var isFlushing = false
    /// Why the last flush left something waiting; nil once everything is up.
    /// Shown in Finance — sync failing in the background has no other voice.
    @Published private(set) var lastError: String?
    /// False when the newest entry could not be written to disk.
    private(set) var lastSaveSucceeded = true

    /// Sends one entry to the vault. A property so the queue logic can be
    /// checked without a token or a network.
    var upload: (ExpenseEntry, TimeInterval?) async throws -> Void = { entry, timeout in
        guard let service = AppConfig.storedService() else { throw GitHubError.missingToken }
        let label = entry.merchant.isEmpty ? "unknown" : String(entry.merchant.prefix(40))
        try await service.putNewFile(path: "\(ExpenseParser.inboxFolder)/\(entry.filename)",
                                     content: ExpenseParser.dropJSON(for: entry),
                                     message: "mobile: expense — \(label)",
                                     timeout: timeout,
                                     pathIsUnique: true)   // filename carries the entry's id
    }

    private let fileURL: URL
    private let syncedLimit = 50
    private var monitor: NWPathMonitor?
    private var networkWasSatisfied: Bool?
    /// The flush currently running, if any. A second caller joins it instead
    /// of being turned away — the intent must wait for *the* upload, whoever
    /// started it, or it returns while the request is still in the air.
    private var inFlight: Task<Bool, Never>?
    /// Set when the queue file exists but could not be read or moved aside:
    /// saving would overwrite expenses that never reached the vault.
    private var persistenceBlocked = false
    /// True inside a running flush (task-local, so it is inherited by the
    /// upload call): a flush requested from in there must not wait for
    /// itself.
    @TaskLocal private static var insideFlush = false

    var pendingCount: Int { entries.filter { !$0.synced }.count }
    var oldestPending: Date? { entries.last(where: { !$0.synced })?.createdAt }

    init(fileURL: URL? = nil, watchNetwork: Bool = true) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("expenses.json")
        }
        load()

        if watchNetwork {
            // Send what is waiting the moment connectivity comes *back* (while
            // the app is alive; otherwise the next tap or app open does it).
            // The monitor's first report describes the current state, not a
            // change: starting a flush from it would race the intent's own
            // bounded flush on a cold launch and win — measured 30/30.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                Task { @MainActor in
                    guard let self else { return }
                    let cameBack = Self.networkCameBack(previous: self.networkWasSatisfied, now: satisfied)
                    self.networkWasSatisfied = satisfied
                    if cameBack { await self.flush() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.alp.SecondBrainCapture.expenses.network"))
            self.monitor = monitor
        }
    }

    /// True only for a transition from "no network" to "network".
    static func networkCameBack(previous: Bool?, now: Bool) -> Bool {
        previous == false && now
    }

    func isSynced(_ id: UUID) -> Bool {
        entries.first(where: { $0.id == id })?.synced ?? false
    }

    /// Record an expense and persist it immediately. Empty input is still
    /// recorded: Wallet sometimes hands Shortcuts nothing, and "a payment
    /// happened at 09:30" is worth more than silence.
    @discardableResult
    func record(rawAmount: String, merchant: String, card: String, note: String = "",
                source: String = "apple-pay", createdAt: Date = Date()) -> ExpenseEntry {
        let entry = ExpenseEntry(rawAmount: Self.tidy(rawAmount), merchant: Self.tidy(merchant),
                                 card: Self.tidy(card), note: Self.tidy(note),
                                 source: source, createdAt: createdAt)
        entries.insert(entry, at: 0)
        trim()
        lastSaveSucceeded = save()
        return entry
    }

    /// Upload unsynced entries, oldest first. Stops when the network or the
    /// token fails (nothing else would get through either) and at `deadline`
    /// — an intent gets ~30 s in the background, so the caller passes a budget
    /// well inside that. A single entry GitHub refuses for its own reasons is
    /// skipped for this round, so it can't hold the others back.
    ///
    /// If a flush is already running, this one waits for it and returns its
    /// result (with that flush's limits). Cancelling a waiting caller cancels
    /// the running flush: the intent's ceiling must end the request, not just
    /// stop watching it.
    /// Returns true when nothing is left waiting.
    @discardableResult
    func flush(requestTimeout: TimeInterval? = nil, deadline: Date? = nil) async -> Bool {
        if Self.insideFlush { return pendingCount == 0 }
        if let running = inFlight { return await join(running) }
        guard pendingCount > 0 else { return true }
        let task = Task { @MainActor [self] in
            await Self.$insideFlush.withValue(true) {
                await run(requestTimeout: requestTimeout, deadline: deadline)
            }
        }
        inFlight = task
        let result = await join(task)
        if inFlight == task { inFlight = nil }
        return result
    }

    private func join(_ task: Task<Bool, Never>) async -> Bool {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func run(requestTimeout: TimeInterval?, deadline: Date?) async -> Bool {
        isFlushing = true
        defer { isFlushing = false; if inFlight?.isCancelled == true { inFlight = nil } }

        // Re-read the list each round instead of iterating a snapshot: an
        // expense recorded while this flush is awaiting the network (a second
        // tap, or the intent firing during a foreground flush) is picked up
        // here rather than left waiting for the next trigger.
        var attempted = Set<UUID>()
        var refusal: String?
        while let entry = entries.last(where: { !$0.synced && !attempted.contains($0.id) }) {
            if Task.isCancelled { return false }
            if let deadline, Date() >= deadline { return false }
            attempted.insert(entry.id)
            do {
                try await sendRetryingOnce(entry, timeout: requestTimeout)
                markSynced(entry.id)
            } catch GitHubError.badResponse(let code, let message) where code != 401 && code != 403 {
                refusal = "GitHub \(code): \(message)"   // this entry only; retried on the next flush
            } catch {
                if !Self.isCancellation(error) { lastError = error.localizedDescription }
                return false
            }
        }
        lastError = refusal
        return pendingCount == 0
    }

    /// 409 is GitHub saying the branch moved while it was writing — the Mac
    /// pushes every minute, so that is a matter of timing. Once more, at once.
    private func sendRetryingOnce(_ entry: ExpenseEntry, timeout: TimeInterval?) async throws {
        do {
            try await upload(entry, timeout)
        } catch GitHubError.badResponse(let code, _) where code == 409 {
            try await upload(entry, timeout)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func markSynced(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].synced = true
        trim()
        save()
    }

    /// Keep every unsynced entry plus the newest `syncedLimit` synced ones.
    private func trim() {
        var kept = 0
        entries = entries.filter { entry in
            if !entry.synced { return true }
            kept += 1
            return kept <= syncedLimit
        }
    }

    /// One line, no stray whitespace: Shortcuts variables can carry newlines.
    private static func tidy(_ s: String) -> String {
        String(s.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let data = try? Data(contentsOf: fileURL),
           let items = try? JSONDecoder().decode([ExpenseEntry].self, from: data) {
            entries = items
            return
        }
        // Unreadable (a future format, a torn write, a file still locked):
        // the next `save()` would overwrite it and with it any expense that
        // never reached the vault. Set it aside — it stays on the phone for
        // recovery — and if even that fails, stop saving over it.
        let aside = fileURL.deletingLastPathComponent()
            .appendingPathComponent("expenses-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            persistenceBlocked = true
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !persistenceBlocked, let data = try? JSONEncoder().encode(entries) else { return false }
        // Not `.completeFileProtection`: the intent has to write while the
        // phone is locked. The default class allows that after first unlock.
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
