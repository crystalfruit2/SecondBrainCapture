import Foundation

/// Compass (schema v7, 2026-11-08): what to give time to today and this week.
///
/// Same "dumb sponge" contract as To Do, Pocket and Finance: the vault engine
/// (`second_brain/.claude/scripts/compass.py`) computes the plan, the ranked
/// list and the weekly budget; the phone only renders the optional top-level
/// `compass` key and appends one log line (`- YYYY-MM-DD · area · 60m · note`)
/// under `## Log` of `compass.file`. Every model decodes defensively — only
/// `file` and `date` are required; a missing or broken `compass` key decodes
/// to nil and hides every Compass surface.
///
/// Foundation only, so `Checks/compass_checks.swift` compiles it with swiftc.

struct CompassPayload: Codable, Equatable {
    let file: String
    let logHeading: String
    let date: String                // vault day (05:00 → 05:00) it was computed for
    let week: String?               // "2026-W46"
    let generated: String?
    let headline: String?
    let capacity: CompassCapacity?
    var areas: [CompassArea]
    let fixed: [CompassFixed]
    let blocks: [CompassBlock]
    let top: [CompassItem]
    let letGo: [CompassLetGo]
    let waiting: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        date = try c.decode(String.self, forKey: .date)
        let heading = (try? c.decodeIfPresent(String.self, forKey: .logHeading)) ?? nil
        logHeading = (heading?.isEmpty == false) ? heading! : "Log"
        week = (try? c.decodeIfPresent(String.self, forKey: .week)) ?? nil
        generated = (try? c.decodeIfPresent(String.self, forKey: .generated)) ?? nil
        headline = (try? c.decodeIfPresent(String.self, forKey: .headline)) ?? nil
        capacity = (try? c.decodeIfPresent(CompassCapacity.self, forKey: .capacity)) ?? nil
        // One bad element drops itself, never the list (and never the dashboard).
        areas = c.failableArray(CompassArea.self, forKey: .areas)
        fixed = c.failableArray(CompassFixed.self, forKey: .fixed)
        blocks = c.failableArray(CompassBlock.self, forKey: .blocks)
        top = c.failableArray(CompassItem.self, forKey: .top)
        letGo = c.failableArray(CompassLetGo.self, forKey: .letGo)
        waiting = c.flexIntIfPresent(forKey: .waiting)
    }

    init(file: String, logHeading: String = "Log", date: String, week: String? = nil, generated: String? = nil,
         headline: String? = nil, capacity: CompassCapacity? = nil, areas: [CompassArea] = [],
         fixed: [CompassFixed] = [], blocks: [CompassBlock] = [], top: [CompassItem] = [],
         letGo: [CompassLetGo] = [], waiting: Int? = nil) {
        self.file = file; self.logHeading = logHeading; self.date = date; self.week = week
        self.generated = generated; self.headline = headline; self.capacity = capacity
        self.areas = areas; self.fixed = fixed; self.blocks = blocks; self.top = top
        self.letGo = letGo; self.waiting = waiting
    }

    func area(_ id: String?) -> CompassArea? {
        guard let id else { return nil }
        return areas.first { $0.id == id }
    }

    var generatedAt: Date? {
        guard let generated else { return nil }
        return ISO8601DateFormatter().date(from: generated)
    }

    /// `fixed` and `blocks` as one chronological timeline.
    var timeline: [CompassSlot] {
        let all = fixed.map(CompassSlot.init(fixed:)) + blocks.map(CompassSlot.init(block:))
        return all.sorted { a, b in
            let x = CompassClock.minutes(a.start) ?? .max, y = CompassClock.minutes(b.start) ?? .max
            return x == y ? (a.isFixed && !b.isFixed) : x < y
        }
    }
}

struct CompassCapacity: Codable, Equatable {
    let freeMin: Int
    let targetMin: Int
    let classMin: Int
    let remainingFreeMin: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        freeMin = c.flexIntIfPresent(forKey: .freeMin) ?? 0
        targetMin = c.flexIntIfPresent(forKey: .targetMin) ?? 0
        classMin = c.flexIntIfPresent(forKey: .classMin) ?? 0
        remainingFreeMin = c.flexIntIfPresent(forKey: .remainingFreeMin)
    }

    init(freeMin: Int, targetMin: Int, classMin: Int = 0, remainingFreeMin: Int? = nil) {
        self.freeMin = freeMin; self.targetMin = targetMin; self.classMin = classMin
        self.remainingFreeMin = remainingFreeMin
    }

    var isOverbooked: Bool { targetMin > freeMin }
}

/// Where an area stands this ISO week, as the vault computed it.
enum CompassStatus: String, CaseIterable {
    case ahead, onPace = "on-pace", behind, belowFloor = "below-floor", idle

    /// Unknown strings from a newer engine fall back to "on pace" (neutral).
    init(raw: String) { self = CompassStatus(rawValue: raw) ?? .onPace }

    var label: String {
        switch self {
        case .ahead: return "ahead"
        case .onPace: return "on pace"
        case .behind: return "behind"
        case .belowFloor: return "below floor"
        case .idle: return "idle"
        }
    }

    /// Colour family name; the view maps it to a system colour.
    enum Tone: Equatable { case good, neutral, warn, bad, muted }
    var tone: Tone {
        switch self {
        case .ahead: return .good
        case .onPace: return .neutral
        case .behind: return .warn
        case .belowFloor: return .bad
        case .idle: return .muted
        }
    }
}

struct CompassArea: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let kind: String
    let targetMin: Int
    let floorMin: Int
    var doneMin: Int
    var loggedMin: Int
    let estimatedMin: Int
    var status: String
    let lastTouched: String?
    let next: String?
    let deadline: String?
    let deadlineLabel: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? id
        emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? nil ?? "•"
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil ?? ""
        targetMin = c.flexIntIfPresent(forKey: .targetMin) ?? 0
        floorMin = c.flexIntIfPresent(forKey: .floorMin) ?? 0
        doneMin = c.flexIntIfPresent(forKey: .doneMin) ?? 0
        loggedMin = c.flexIntIfPresent(forKey: .loggedMin) ?? 0
        estimatedMin = c.flexIntIfPresent(forKey: .estimatedMin) ?? 0
        let raw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        status = raw ?? (targetMin == 0 ? CompassStatus.idle.rawValue : CompassStatus.onPace.rawValue)
        lastTouched = (try? c.decodeIfPresent(String.self, forKey: .lastTouched)) ?? nil
        next = (try? c.decodeIfPresent(String.self, forKey: .next)) ?? nil
        deadline = (try? c.decodeIfPresent(String.self, forKey: .deadline)) ?? nil
        deadlineLabel = (try? c.decodeIfPresent(String.self, forKey: .deadlineLabel)) ?? nil
    }

    init(id: String, name: String, emoji: String = "•", kind: String = "study", targetMin: Int = 0,
         floorMin: Int = 0, doneMin: Int = 0, loggedMin: Int = 0, estimatedMin: Int = 0,
         status: String = "on-pace", lastTouched: String? = nil, next: String? = nil,
         deadline: String? = nil, deadlineLabel: String? = nil) {
        self.id = id; self.name = name; self.emoji = emoji; self.kind = kind
        self.targetMin = targetMin; self.floorMin = floorMin; self.doneMin = doneMin
        self.loggedMin = loggedMin; self.estimatedMin = estimatedMin; self.status = status
        self.lastTouched = lastTouched; self.next = next; self.deadline = deadline
        self.deadlineLabel = deadlineLabel
    }

    var statusKind: CompassStatus { CompassStatus(raw: status) }
    /// 0…1 of the weekly target (0 when there is no target).
    var progress: Double { targetMin > 0 ? min(1, Double(doneMin) / Double(targetMin)) : 0 }
    var floorFraction: Double { targetMin > 0 ? min(1, Double(floorMin) / Double(targetMin)) : 0 }
}

struct CompassFixed: Codable, Equatable {
    let start: String
    let end: String?
    let title: String
    let kind: String                // class | sport | …
    let area: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(String.self, forKey: .start)
        end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil ?? "class"
        area = (try? c.decodeIfPresent(String.self, forKey: .area)) ?? nil
    }

    init(start: String, end: String?, title: String, kind: String = "class", area: String? = nil) {
        self.start = start; self.end = end; self.title = title; self.kind = kind; self.area = area
    }
}

struct CompassBlock: Codable, Equatable {
    let start: String
    let end: String
    let minutes: Int
    let area: String
    let kind: String
    let title: String
    let why: [String]
    let taskId: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(String.self, forKey: .start)
        end = try c.decode(String.self, forKey: .end)
        area = (try? c.decodeIfPresent(String.self, forKey: .area)) ?? nil ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil ?? "study"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil ?? ""
        why = (try? c.decodeIfPresent([String].self, forKey: .why)) ?? nil ?? []
        taskId = (try? c.decodeIfPresent(String.self, forKey: .taskId)) ?? nil
        minutes = c.flexIntIfPresent(forKey: .minutes) ?? CompassClock.duration(start, end) ?? 0
    }

    init(start: String, end: String, minutes: Int? = nil, area: String, kind: String = "study",
         title: String, why: [String] = [], taskId: String? = nil) {
        self.start = start; self.end = end; self.area = area; self.kind = kind; self.title = title
        self.why = why; self.taskId = taskId
        self.minutes = minutes ?? CompassClock.duration(start, end) ?? 0
    }
}

struct CompassItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let area: String?
    let score: Int
    let minutes: Int?
    let due: String?
    let why: [String]
    let source: String?
    let kind: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? title
        area = (try? c.decodeIfPresent(String.self, forKey: .area)) ?? nil
        score = c.flexIntIfPresent(forKey: .score) ?? 0
        minutes = c.flexIntIfPresent(forKey: .minutes)
        due = (try? c.decodeIfPresent(String.self, forKey: .due)) ?? nil
        why = (try? c.decodeIfPresent([String].self, forKey: .why)) ?? nil ?? []
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil ?? "task"
    }
}

struct CompassLetGo: Codable, Equatable, Identifiable {
    let title: String
    let reason: String
    var id: String { title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil ?? ""
    }
}

// MARK: - Timeline + the "Now" picker

/// One row of today's timeline: a fixed item (class, sport) or a planned block.
struct CompassSlot: Identifiable, Equatable {
    let start: String
    let end: String?
    let title: String
    let area: String?
    let kind: String
    let isFixed: Bool
    let why: [String]
    let minutes: Int

    var id: String { "\(isFixed ? "f" : "b")|\(start)|\(area ?? "")|\(title)" }

    init(fixed f: CompassFixed) {
        start = f.start; end = f.end; title = f.title; area = f.area; kind = f.kind
        isFixed = true; why = []
        minutes = CompassClock.duration(f.start, f.end) ?? 0
    }

    init(block b: CompassBlock) {
        start = b.start; end = b.end; title = b.title; area = b.area; kind = b.kind
        isFixed = false; why = b.why; minutes = b.minutes
    }

    /// `14:15–15:45`, or `14:15` without an end.
    var timeLabel: String { end.map { "\(start)–\($0)" } ?? start }

    /// [start, end) in minutes of the vault day; a slot without an end lasts an hour.
    var range: Range<Int>? {
        guard let s = CompassClock.minutes(start) else { return nil }
        var e = end.flatMap(CompassClock.minutes) ?? s + 60
        if e <= s { e += 24 * 60 }
        return s..<e
    }

    func hasEnded(at nowMin: Int) -> Bool { (range?.upperBound ?? .max) <= nowMin }
    func hasStarted(at nowMin: Int) -> Bool { (range?.lowerBound ?? .max) <= nowMin }
}

enum CompassNow: Equatable {
    case current(CompassSlot)
    case next(CompassSlot)
    case done
}

/// The vault-day clock for Compass. Reuses `PocketClock` (the 05:00 rule) —
/// times are minutes since the vault day's midnight, so 01:30 is 25:30.
enum CompassClock {
    static let dayStart = PocketClock.dayStartHour * 60

    /// `"14:15"` → 855; `"01:30"` → 1530 (before 05:00 belongs to the night).
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        let v = h * 60 + m
        return v < dayStart ? v + 24 * 60 : v
    }

    static func duration(_ start: String, _ end: String?) -> Int? {
        guard let s = minutes(start), let end, var e = minutes(end) else { return nil }
        if e <= s { e += 24 * 60 }
        return e - s
    }

    /// The vault day `now` belongs to, as `YYYY-MM-DD`.
    static func today(_ now: Date) -> String {
        DateFormatter.vaultDay.string(from: PocketClock.vaultDay(of: now))
    }

    /// Minutes since the vault day's midnight (05:00 → 300, 01:00 next day → 1500).
    static func nowMinutes(_ now: Date) -> Int {
        let day = PocketClock.vaultDay(of: now)
        return Int(now.timeIntervalSince(day) / 60)
    }

    static func isStale(_ payload: CompassPayload, now: Date) -> Bool { payload.date != today(now) }

    /// Current block first, then a current fixed item (in class → say so), then
    /// the next block or fixed item still ahead; "done" once nothing is left.
    /// A payload for an earlier vault day is over; one for a later day hasn't begun.
    static func pick(_ payload: CompassPayload, now: Date) -> CompassNow {
        let slots = payload.timeline.filter { $0.range != nil }
        let today = today(now)
        if payload.date < today { return .done }
        if payload.date > today { return slots.first.map(CompassNow.next) ?? .done }
        let t = nowMinutes(now)
        if let b = slots.first(where: { !$0.isFixed && $0.range!.contains(t) }) { return .current(b) }
        if let f = slots.first(where: { $0.isFixed && $0.range!.contains(t) }) { return .current(f) }
        if let n = slots.first(where: { $0.range!.lowerBound > t }) { return .next(n) }
        return .done
    }

    /// Where a "✓ Done" button belongs: sport once it has started, a block once it has ended.
    static func canMarkDone(_ slot: CompassSlot, payload: CompassPayload, now: Date) -> Bool {
        guard slot.area?.isEmpty == false else { return false }
        let today = today(now)
        if payload.date < today { return !slot.isFixed || slot.kind == "sport" }
        guard payload.date == today else { return false }
        let t = nowMinutes(now)
        if slot.isFixed { return slot.kind == "sport" && slot.hasStarted(at: t) }
        return slot.hasEnded(at: t)
    }
}

// MARK: - Logging time

/// One logged session. Persisted *before* any network call (offline-first,
/// like every other write in `DashboardStore`), and kept after it syncs until
/// a rebuilt dashboard has counted it — so a refresh in between doesn't take
/// the minutes back off the bar.
struct PendingCompassLog: Codable, Identifiable, Equatable {
    let id: UUID
    let file: String
    let heading: String             // "## Log"
    let date: String                // vault day, YYYY-MM-DD
    let areaId: String
    let minutes: Int
    let note: String
    /// The timeline slot a "✓ Done" came from, so its button hides afterwards.
    let slotID: String?
    let createdAt: Date
    var syncedAt: Date?

    init(file: String, heading: String, date: String, areaId: String, minutes: Int, note: String,
         slotID: String? = nil, createdAt: Date = Date()) {
        self.id = UUID(); self.file = file; self.heading = heading; self.date = date
        self.areaId = areaId; self.minutes = minutes; self.note = note; self.slotID = slotID
        self.createdAt = createdAt; self.syncedAt = nil
    }

    var line: String { CompassLog.line(date: date, areaId: areaId, minutes: minutes, note: note) }
    var commitMessage: String { "mobile: compass log — \(areaId) \(minutes)m" }
}

enum CompassLog {
    static let chips = [15, 30, 45, 60, 90, 120]
    static let defaultNote = "from phone"

    /// `- 2026-11-09 · apc · 60m · from phone` — the exact contract line.
    static func line(date: String, areaId: String, minutes: Int, note: String) -> String {
        let clean = note.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return "- \(date) · \(areaId) · \(max(1, minutes))m · \(clean.isEmpty ? defaultNote : clean)"
    }

    /// `"Log"` → `"## Log"` (a value that already carries `#`s is normalised).
    static func heading(_ logHeading: String) -> String {
        let bare = logHeading.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return "## " + (bare.isEmpty ? "Log" : bare)
    }

    /// Written only if the vault has no Compass note yet (insertLine's 404 path).
    static let template = """
    ---
    title: "Compass"
    type: compass
    tags:
      - area
      - planning
    status: active
    ---

    # 🧭 Compass

    ## Log
    """

    /// `"2026-W46"` for a vault day.
    static func isoWeek(of day: String) -> String? {
        guard let d = DateFormatter.vaultDay.date(from: day) else { return nil }
        let c = TodoClock.iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        guard let y = c.yearForWeekOfYear, let w = c.weekOfYear else { return nil }
        return String(format: "%04d-W%02d", y, w)
    }

    /// The optimistic bump: minutes go on the bar at once. Status only moves
    /// across lines the phone can see (floor, target); pace is the vault's call.
    static func bump(_ payload: CompassPayload, areaId: String, minutes: Int) -> CompassPayload {
        guard let i = payload.areas.firstIndex(where: { $0.id == areaId }), minutes > 0 else { return payload }
        var p = payload
        var a = p.areas[i]
        a.doneMin += minutes
        a.loggedMin += minutes
        if a.targetMin > 0 && a.doneMin >= a.targetMin {
            a.status = CompassStatus.ahead.rawValue
        } else if a.statusKind == .belowFloor && a.doneMin >= a.floorMin {
            a.status = CompassStatus.behind.rawValue
        }
        p.areas[i] = a
        return p
    }

    /// Whether a fresh payload still lacks this log: not synced yet, or synced
    /// after the payload was generated. Only logs of the payload's own week count.
    static func needsReplay(_ log: PendingCompassLog, over payload: CompassPayload) -> Bool {
        if let week = payload.week, let mine = isoWeek(of: log.date), week != mine { return false }
        guard let synced = log.syncedAt else { return true }
        guard let generated = payload.generatedAt else { return false }
        return generated < synced
    }

    static func applying(_ logs: [PendingCompassLog], to payload: CompassPayload) -> CompassPayload {
        logs.filter { needsReplay($0, over: payload) }
            .reduce(payload) { bump($0, areaId: $1.areaId, minutes: $1.minutes) }
    }
}

// MARK: - Display strings (pure, so the checks can pin them)

enum CompassFormat {
    /// 150 → "2.5", 240 → "4", 20 → "0.3".
    static func hours(_ minutes: Int) -> String {
        let h = (Double(minutes) / 60 * 10).rounded() / 10
        return h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
    }

    /// "2.5 / 4 h"
    static func progress(_ area: CompassArea) -> String {
        "\(hours(area.doneMin)) / \(hours(area.targetMin)) h"
    }

    /// "31 h free after classes · targets ask 29 h"
    static func capacity(_ c: CompassCapacity) -> String {
        "\(hours(c.freeMin)) h free after classes · targets ask \(hours(c.targetMin)) h"
    }

    /// The engine often starts a title with the area emoji ("🎛️ A&PC: …"); the
    /// row already shows that emoji, so the title drops it. Text titles pass through.
    static func dropLeadingEmoji(_ title: String) -> String {
        guard let first = title.first, isEmoji(first) else { return title }
        let rest = title.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    static func isEmoji(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, s.properties.isEmoji else { return false }
        return s.properties.isEmojiPresentation || c.unicodeScalars.count > 1
    }

    /// "2026-11-11" → "Wed 11.11"
    static func shortDay(_ day: String) -> String {
        guard let d = DateFormatter.vaultDay.date(from: day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d.MM"
        return f.string(from: d)
    }
}

// MARK: - Tolerant decoding helpers

extension KeyedDecodingContainer {
    /// An array where a bad element drops itself; a missing or wrong-typed key gives [].
    func failableArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        ((try? decodeIfPresent([Failable<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// An integer that may arrive as `90`, `90.0` or `"90"`.
    func flexIntIfPresent(forKey key: Key) -> Int? {
        if let i = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return i }
        if let d = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil, d.isFinite { return Int(d.rounded()) }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(s) }
        return nil
    }
}
