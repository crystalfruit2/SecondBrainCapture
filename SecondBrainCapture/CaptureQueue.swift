import Foundation
import Network

/// One captured note waiting to be committed. `createdAt` is preserved so the
/// note keeps its real capture time even if it syncs hours later.
struct PendingCapture: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(text: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
    }
}

/// Durable, offline-first queue for captures.
///
/// Every capture is appended here and persisted to disk *before* any network
/// call, so a note is never lost to a flaky lab connection, a dead token, or
/// the app being killed mid-commit. `flush()` drains the queue in order and is
/// triggered on capture, on network reconnect, and when the app foregrounds.
@MainActor
final class CaptureQueue: ObservableObject {
    @Published private(set) var pending: [PendingCapture] = []
    @Published private(set) var isFlushing = false

    /// Supplies a configured service, or nil if the app isn't set up yet
    /// (no token). Wired up by the app once AppConfig exists.
    var serviceProvider: () -> GitHubService? = { nil }

    private let monitor = NWPathMonitor()
    private let fileURL: URL

    var count: Int { pending.count }

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("capture-queue.json")
        load()

        // Retry automatically the moment connectivity comes back.
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "com.alp.SecondBrainCapture.network"))
    }

    /// Add a capture to the queue and persist it immediately.
    func enqueue(_ text: String, createdAt: Date = Date()) {
        pending.append(PendingCapture(text: text, createdAt: createdAt))
        save()
    }

    /// Commit queued captures in order. Stops at the first failure so order is
    /// preserved and a transient error doesn't drop later items.
    /// Returns true only if the queue is fully drained.
    @discardableResult
    func flush() async -> Bool {
        guard !isFlushing, !pending.isEmpty, let service = serviceProvider() else {
            return pending.isEmpty
        }
        isFlushing = true
        defer { isFlushing = false }

        while let item = pending.first {
            do {
                _ = try await service.commitNote(text: item.text, date: item.createdAt)
                pending.removeFirst()
                save()
            } catch {
                return false   // still offline / bad token — keep the rest queued
            }
        }
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([PendingCapture].self, from: data) else { return }
        pending = items
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
