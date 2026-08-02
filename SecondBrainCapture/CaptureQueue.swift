import Foundation
import Network

/// One captured note waiting to be committed. `createdAt` is preserved so the
/// note keeps its real capture time even if it syncs hours later.
struct PendingCapture: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    /// Local filename of a photo staged in `ImageStore`, for photo captures.
    /// Optional so queues written by older builds still decode.
    let imageFilename: String?

    init(text: String, createdAt: Date = Date(), imageFilename: String? = nil) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
        self.imageFilename = imageFilename
    }
}

/// A lightweight history entry for the "Recent" list — separate from
/// `PendingCapture` because it survives after a capture has synced, purely
/// for at-a-glance confirmation of what was captured recently.
struct RecentCapture: Codable, Identifiable, Equatable {
    let id: UUID
    let preview: String
    let createdAt: Date
    var synced: Bool
    /// Optional so history written by older builds still decodes.
    var hasImage: Bool?

    var isPhoto: Bool { hasImage == true }
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
    /// Last few captures (queued or synced), newest first — for the "Recent" list.
    @Published private(set) var recent: [RecentCapture] = []

    /// Supplies a configured service, or nil if the app isn't set up yet
    /// (no token). Wired up by the app once AppConfig exists.
    var serviceProvider: () -> GitHubService? = { nil }

    private let monitor = NWPathMonitor()
    private let fileURL: URL
    private let recentURL: URL
    private let recentLimit = 15

    var count: Int { pending.count }

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("capture-queue.json")
        recentURL = dir.appendingPathComponent("recent-captures.json")
        load()
        loadRecent()

        // Retry automatically the moment connectivity comes back.
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "com.alp.SecondBrainCapture.network"))
    }

    /// Add a capture to the queue and persist it immediately.
    /// `imageFilename` refers to a photo already staged by `ImageStore`.
    func enqueue(_ text: String, createdAt: Date = Date(), imageFilename: String? = nil) {
        let item = PendingCapture(text: text, createdAt: createdAt, imageFilename: imageFilename)
        pending.append(item)
        save()

        // A photo with no legible text still needs something to show in Recent.
        let preview = text.isEmpty && imageFilename != nil ? "Photo" : String(text.prefix(80))
        recent.insert(RecentCapture(id: item.id, preview: preview, createdAt: createdAt,
                                    synced: false, hasImage: imageFilename != nil), at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        saveRecent()
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
                // Image first, so the note is never committed pointing at an
                // attachment that isn't in the repo yet.
                if let filename = item.imageFilename, let data = ImageStore.load(filename) {
                    try await service.commitImage(data: data, filename: filename)
                    try await service.commitNote(text: item.text, date: item.createdAt,
                                                 imageName: filename)
                    ImageStore.delete(filename)
                } else {
                    // A missing staged file means the note text is all we have
                    // left; committing it plain beats blocking the queue forever.
                    try await service.commitNote(text: item.text, date: item.createdAt)
                }
                pending.removeFirst()
                save()
                markSynced(item.id)
            } catch {
                return false   // still offline / bad token — keep the rest queued
            }
        }
        return true
    }

    private func markSynced(_ id: UUID) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        recent[index].synced = true
        saveRecent()
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

    private func loadRecent() {
        guard let data = try? Data(contentsOf: recentURL),
              let items = try? JSONDecoder().decode([RecentCapture].self, from: data) else { return }
        recent = items
    }

    private func saveRecent() {
        guard let data = try? JSONEncoder().encode(recent) else { return }
        try? data.write(to: recentURL, options: .atomic)
    }
}
