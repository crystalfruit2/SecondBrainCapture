import Foundation

/// Models for `dashboard.json` — a single prebuilt file the vault regenerates
/// (via a GitHub Action) and the phone only ever reads. The app deliberately
/// does no vault parsing itself: all the intelligence stays where Claude has
/// full context, and the phone stays a thin, fast client.
///
/// Every model decodes defensively. A dashboard produced by a newer generator
/// must never crash an older build of the app — unknown values degrade to
/// sensible defaults rather than throwing.

enum TaskBucket: String, Codable, CaseIterable, Hashable {
    case overdue, today, upcoming

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskBucket(rawValue: raw) ?? .upcoming
    }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        }
    }
}

/// One markdown checkbox somewhere in the vault, located precisely enough
/// (`file` + `line` + `raw`) that the app can flip it with a single-line edit
/// instead of rewriting the note.
struct DashboardTask: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let text: String
    var done: Bool
    let bucket: TaskBucket
    let due: String?
    let overdueDays: Int
    let project: String?
    let file: String
    let line: Int
    let raw: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        bucket = try c.decodeIfPresent(TaskBucket.self, forKey: .bucket) ?? .upcoming
        due = try c.decodeIfPresent(String.self, forKey: .due)
        overdueDays = try c.decodeIfPresent(Int.self, forKey: .overdueDays) ?? 0
        project = try c.decodeIfPresent(String.self, forKey: .project)
        file = try c.decode(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
    }

    /// Memberwise init kept for previews and for locally-mutated copies.
    init(id: String, text: String, done: Bool, bucket: TaskBucket, due: String? = nil,
         overdueDays: Int = 0, project: String? = nil, file: String, line: Int, raw: String) {
        self.id = id; self.text = text; self.done = done; self.bucket = bucket
        self.due = due; self.overdueDays = overdueDays; self.project = project
        self.file = file; self.line = line; self.raw = raw
    }

    var dueDate: Date? {
        guard let due else { return nil }
        return DateFormatter.vaultDay.date(from: due)
    }

    /// Short trailing label: "2d" overdue, else a weekday/date hint, else the project.
    /// The Daily note's task lines carry a whole paragraph of Claude-written
    /// context ("… → note · 28.09 akşam: …"). On a phone that reads as a wall
    /// of text, so the Vault segment shows only the first clause and expands
    /// on tap. Pure heuristics: cut at the first " → ", " · " or " — " that
    /// comes after a few words, and drop the "(carried)" marker.
    var shortText: String {
        var s = text.replacingOccurrences(of: "(carried)", with: "")
        for sep in [" → ", " · ", " — ", " ¬ "] {
            if let r = s.range(of: sep), s.distance(from: s.startIndex, to: r.lowerBound) >= 12 {
                s = String(s[..<r.lowerBound])
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // A cut inside a parenthesis leaves "Nudge (bugün, sırayla" — drop the open clause.
        if s.filter({ $0 == "(" }).count > s.filter({ $0 == ")" }).count,
           let open = s.lastIndex(of: "("), s.distance(from: s.startIndex, to: open) >= 6 {
            s = String(s[..<open])
        }
        while let last = s.last, ":—–-·,; ".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    var isTruncated: Bool { shortText.count < text.trimmingCharacters(in: .whitespaces).count - 2 }

    var trailingPill: (text: String, style: PillStyle)? {
        if bucket == .overdue && overdueDays > 0 {
            return ("\(overdueDays)d", .overdue)
        }
        if bucket == .upcoming, let date = dueDate {
            return (Self.shortDayLabel(for: date), .date)
        }
        if let project, !project.isEmpty {
            return (project, .project)
        }
        return nil
    }

    private static func shortDayLabel(for date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: date)).day ?? 0
        if days <= 7 && days >= 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

enum PillStyle { case overdue, project, date }

/// One line of `Areas/Market-List.md` — flat, no buckets or due dates, just a
/// checkbox that syncs the same way a task's does.
struct MarketItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let text: String
    var done: Bool
    let file: String
    let line: Int
    let raw: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        file = try c.decode(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
    }

    init(id: String, text: String, done: Bool, file: String, line: Int, raw: String) {
        self.id = id; self.text = text; self.done = done
        self.file = file; self.line = line; self.raw = raw
    }
}

/// A single nudge from the Companion — the one thing Alp would otherwise miss.
/// Computed vault-side, where the review cadence and project staleness are known.
struct RockyNudge: Codable, Equatable, Hashable {
    let kind: String
    let message: String
}

struct AgendaItem: Codable, Identifiable, Equatable, Hashable {
    let time: String
    let title: String
    let subtitle: String?

    var id: String { "\(time)|\(title)" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    }

    init(time: String, title: String, subtitle: String? = nil) {
        self.time = time; self.title = title; self.subtitle = subtitle
    }
}

struct ProjectSummary: Codable, Identifiable, Equatable, Hashable {
    let name: String
    let status: String
    let note: String?
    let nextAction: String?
    let openTasks: Int

    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        nextAction = try c.decodeIfPresent(String.self, forKey: .nextAction)
        openTasks = try c.decodeIfPresent(Int.self, forKey: .openTasks) ?? 0
    }

    init(name: String, status: String, note: String? = nil, nextAction: String? = nil, openTasks: Int = 0) {
        self.name = name; self.status = status; self.note = note
        self.nextAction = nextAction; self.openTasks = openTasks
    }
}

/// One long-arc life thread, mirrored read-only from `Areas/Life-Threads.md`.
struct CompanionThread: Codable, Identifiable, Equatable, Hashable {
    let title: String
    let status: String
    let latestMovement: String?
    let nextPull: String?

    var id: String { title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "🔥"
        latestMovement = try c.decodeIfPresent(String.self, forKey: .latestMovement)
        nextPull = try c.decodeIfPresent(String.self, forKey: .nextPull)
    }

    init(title: String, status: String = "🔥", latestMovement: String? = nil, nextPull: String? = nil) {
        self.title = title; self.status = status
        self.latestMovement = latestMovement; self.nextPull = nextPull
    }
}

/// One entry from `Areas/Decision-Log.md` — the choice, not the full reasoning.
struct CompanionDecision: Codable, Identifiable, Equatable, Hashable {
    let title: String
    let date: String?
    let choice: String?
    let followUp: String?

    var id: String { "\(title)|\(date ?? "")" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date)
        choice = try c.decodeIfPresent(String.self, forKey: .choice)
        followUp = try c.decodeIfPresent(String.self, forKey: .followUp)
    }

    init(title: String, date: String? = nil, choice: String? = nil, followUp: String? = nil) {
        self.title = title; self.date = date; self.choice = choice; self.followUp = followUp
    }
}

/// One live idea from `Areas/Idea-Garden.md`'s Seeds section. Dead/superseded
/// seeds are filtered out vault-side, so anything that reaches the phone is
/// still open.
struct CompanionSeed: Codable, Identifiable, Equatable, Hashable {
    let title: String
    let summary: String?

    var id: String { title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }

    init(title: String, summary: String? = nil) {
        self.title = title; self.summary = summary
    }
}

/// The three Companion organs, read-only on the phone — Claude feeds these
/// during normal vault work, but Alp never sees them unless he opens Obsidian.
struct CompanionData: Codable, Equatable {
    let threads: [CompanionThread]
    let decisions: [CompanionDecision]
    let seeds: [CompanionSeed]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try c.decodeIfPresent([CompanionThread].self, forKey: .threads) ?? []
        decisions = try c.decodeIfPresent([CompanionDecision].self, forKey: .decisions) ?? []
        seeds = try c.decodeIfPresent([CompanionSeed].self, forKey: .seeds) ?? []
    }

    init(threads: [CompanionThread] = [], decisions: [CompanionDecision] = [], seeds: [CompanionSeed] = []) {
        self.threads = threads; self.decisions = decisions; self.seeds = seeds
    }

    var isEmpty: Bool { threads.isEmpty && decisions.isEmpty && seeds.isEmpty }
}

/// Today's `### Health log` bullets, mirrored read-only so the Health tab can
/// show "already logged today" instead of feeling write-only.
struct HealthToday: Codable, Equatable {
    let loggedToday: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loggedToday = try c.decodeIfPresent([String].self, forKey: .loggedToday) ?? []
    }

    init(loggedToday: [String] = []) { self.loggedToday = loggedToday }
}

/// One weekly §Sicil row from `Areas/Finance.md` — `cells` is keyed by the
/// column name (Turkish / `+` / emoji keys are fine in a `[String: String]`);
/// iterate `FinancePayload.sicilColumns` for the order, never the dictionary.
struct SicilRow: Codable, Identifiable, Equatable {
    let date: String
    let cells: [String: String]
    var id: String { date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        cells = try c.decodeIfPresent([String: String].self, forKey: .cells) ?? [:]
    }

    init(date: String, cells: [String: String]) { self.date = date; self.cells = cells }
}

/// The newest Daily note's `## 💰 Pazar portföy brifingi` block, as markdown.
struct FinanceBrief: Codable, Equatable {
    let date: String
    let file: String?
    let markdown: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
    }

    init(date: String, file: String? = nil, markdown: String) { self.date = date; self.file = file; self.markdown = markdown }
}

/// Faz S-G4a — the cloud Sentinel's close card (`card.json` on the vault's
/// `sentinel-state` branch). Lines are shown verbatim; `stale` is decided by
/// `build_dashboard.py`, never here.
struct SentinelCard: Codable, Equatable {
    let key: String
    let date: String?
    let title: String
    let lines: [String]
    let notify: Bool
    let stale: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }
}

/// One unread Sentinel alert (rule-card wording from the watcher — never an order).
struct SentinelAlert: Codable, Equatable, Identifiable {
    let key: String
    let ts: String?
    let title: String
    let msg: String
    var id: String { key }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? UUID().uuidString
        ts = try c.decodeIfPresent(String.self, forKey: .ts)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        msg = try c.decodeIfPresent(String.self, forKey: .msg) ?? ""
    }
}

struct FinanceSentinel: Codable, Equatable {
    let checkedAt: String?
    let failures: Int
    let pushFailures: Int
    let card: SentinelCard?
    let alerts: [SentinelAlert]
    let watchGeneratedAt: String?
    let watchStale: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt)
        failures = try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        pushFailures = try c.decodeIfPresent(Int.self, forKey: .pushFailures) ?? 0
        card = try c.decodeIfPresent(SentinelCard.self, forKey: .card)
        alerts = try c.decodeIfPresent([SentinelAlert].self, forKey: .alerts) ?? []
        watchGeneratedAt = try c.decodeIfPresent(String.self, forKey: .watchGeneratedAt)
        watchStale = try c.decodeIfPresent(Bool.self, forKey: .watchStale) ?? false
    }
}

/// One row of the vault's spending ledger, already formatted for display.
struct SpendingRow: Codable, Equatable, Identifiable {
    let id: String
    let date: String        // YYYY-MM-DD
    let time: String        // HH:MM
    let merchant: String
    let amount: String      // "4,50", or "?" when the vault couldn't read it
    let currency: String
    let category: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant) ?? ""
        amount = try c.decodeIfPresent(String.self, forKey: .amount) ?? "?"
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
    }

    /// "06.10" — day and month are enough inside a month view.
    var shortDate: String {
        let parts = date.split(separator: "-")
        return parts.count == 3 ? "\(parts[2]).\(parts[1])" : date
    }
}

struct SpendingCategory: Codable, Equatable, Identifiable {
    let name: String
    let total: String
    let count: Int
    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        total = try c.decodeIfPresent(String.self, forKey: .total) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }
}

/// This month's spending as the vault computed it (`fin/expenses.py`
/// `dashboard_payload`): card taps this app logged plus anything entered by
/// hand on the Mac. Same contract as the rest of Finance — finished display
/// strings only; the phone parses no number and words no sentence.
struct SpendingPayload: Codable, Equatable {
    let month: String
    let label: String           // "Ekim 2026"
    let symbol: String          // "€"
    let total: String           // "312,40"
    let count: Int
    let countLine: String       // "14 işlem"
    let budgetLine: String?     // "aylık ödeme €1.000,00 → kalan €679,60"
    let byCategory: [SpendingCategory]
    let recent: [SpendingRow]
    let warnings: [String]      // what the total leaves out (unreadable amounts, other currencies)
    let note: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decodeIfPresent(String.self, forKey: .month) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        total = try c.decodeIfPresent(String.self, forKey: .total) ?? "—"
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        countLine = try c.decodeIfPresent(String.self, forKey: .countLine) ?? "\(count)"
        budgetLine = try c.decodeIfPresent(String.self, forKey: .budgetLine)
        byCategory = try c.decodeIfPresent([SpendingCategory].self, forKey: .byCategory) ?? []
        recent = try c.decodeIfPresent([SpendingRow].self, forKey: .recent) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// Read-only mirror of what `/finance` keeps in the vault (schema v3 `finance`
/// key, generated by `build_dashboard.py:parse_finance`). Faz 0 contract: the
/// phone shows data and the record, never an order.
struct FinancePayload: Codable, Equatable {
    let sicil: [SicilRow]          // oldest → newest, ≤ 26 rows
    let sicilColumns: [String]
    let blocks: [String: String]   // record / rules / calendar markdown, each ≤ 2000 chars
    let brief: FinanceBrief?
    let source: String?
    let sentinel: FinanceSentinel?
    /// Added 2026-10-06; older dashboards lack it → nil.
    let spending: SpendingPayload?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sicil = try c.decodeIfPresent([SicilRow].self, forKey: .sicil) ?? []
        sicilColumns = try c.decodeIfPresent([String].self, forKey: .sicilColumns) ?? []
        blocks = try c.decodeIfPresent([String: String].self, forKey: .blocks) ?? [:]
        brief = try c.decodeIfPresent(FinanceBrief.self, forKey: .brief)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        sentinel = try c.decodeIfPresent(FinanceSentinel.self, forKey: .sentinel)
        spending = try c.decodeIfPresent(SpendingPayload.self, forKey: .spending)
    }

    init(sicil: [SicilRow] = [], sicilColumns: [String] = [], blocks: [String: String] = [:],
         brief: FinanceBrief? = nil, source: String? = nil) {
        self.sicil = sicil; self.sicilColumns = sicilColumns; self.blocks = blocks; self.brief = brief; self.source = source
        self.sentinel = nil
        self.spending = nil
    }

    var latest: SicilRow? { sicil.last }
    var newestFirst: [SicilRow] { sicil.reversed() }
    /// The portfolio half only — Spending has its own sections and its own
    /// empty state, so it doesn't count here.
    var isEmpty: Bool { sicil.isEmpty && blocks.isEmpty && brief == nil && sentinel == nil }
    var unreadAlerts: Int { sentinel?.alerts.count ?? 0 }
}

// MARK: - To Do (schema v4, 2026-09-28)

/// Which `##` section of `Areas/To-Do.md` an item lives under. Unknown values
/// from a newer generator degrade to `.todo` rather than throwing.
enum TodoSection: String, Codable, CaseIterable, Hashable {
    case routine, todo, errand

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TodoSection(rawValue: raw) ?? .todo
    }

    /// The exact heading the vault note uses — new items are inserted under it.
    var heading: String {
        switch self {
        case .routine: return "## Routines"
        case .todo: return "## To do"
        case .errand: return "## Errands"
        }
    }
}

enum TodoRecur: String, Codable, Hashable {
    case daily, weekly
}

/// Where an item falls relative to the phone's clock. Computed on-device, not
/// by CI: the runner is up to three hours stale and "today" flips at Alp's
/// midnight, not UTC's.
enum TodoBucket: Hashable {
    case overdue(days: Int), today, thisWeek, later, anytime
}

struct TodoItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let text: String
    let section: TodoSection
    let recur: TodoRecur?
    /// CI's view of done-ness. For one-offs it's the checkbox; for routines the
    /// phone ignores it and derives from `lastDone` (see `isDone(on:)`).
    var done: Bool
    var due: String?
    let time: String?
    var lastDone: String?
    let file: String
    let line: Int
    /// The vault line as the phone believes it currently reads. Updated after
    /// every local edit so the next edit's `expectedLine` still locates it.
    var raw: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        section = try c.decodeIfPresent(TodoSection.self, forKey: .section) ?? .todo
        recur = try? c.decodeIfPresent(TodoRecur.self, forKey: .recur)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        due = try c.decodeIfPresent(String.self, forKey: .due)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        lastDone = try c.decodeIfPresent(String.self, forKey: .lastDone)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
    }

    init(id: String, text: String, section: TodoSection, recur: TodoRecur? = nil, done: Bool = false,
         due: String? = nil, time: String? = nil, lastDone: String? = nil,
         file: String, line: Int, raw: String) {
        self.id = id; self.text = text; self.section = section; self.recur = recur; self.done = done
        self.due = due; self.time = time; self.lastDone = lastDone
        self.file = file; self.line = line; self.raw = raw
    }

    var dueDate: Date? {
        guard let due else { return nil }
        return DateFormatter.vaultDay.date(from: due)
    }

    var lastDoneDate: Date? {
        guard let lastDone else { return nil }
        return DateFormatter.vaultDay.date(from: lastDone)
    }

    /// `⏰ 10:00` → (10, 0). Nil when the marker is absent or malformed.
    var timeComponents: (hour: Int, minute: Int)? {
        guard let time else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// Done *as of this device's clock*. A daily routine is done if stamped
    /// today; a weekly one if stamped in the current ISO week (Mon–Sun). No
    /// nightly reset needed — yesterday's stamp simply stops matching.
    func isDone(on day: Date = Date()) -> Bool {
        switch recur {
        case .daily:
            guard let last = lastDoneDate else { return false }
            return Calendar.current.isDate(last, inSameDayAs: day)
        case .weekly:
            guard let last = lastDoneDate else { return false }
            return TodoClock.isSameISOWeek(last, day)
        case nil:
            return done
        }
    }

    func bucket(on day: Date = Date()) -> TodoBucket {
        guard let dueDate else { return .anytime }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let dueStart = cal.startOfDay(for: dueDate)
        if dueStart < start {
            return .overdue(days: cal.dateComponents([.day], from: dueStart, to: start).day ?? 1)
        }
        if dueStart == start { return .today }
        if TodoClock.isSameISOWeek(dueStart, day) { return .thisWeek }
        return .later
    }

    /// When a reminder should fire: the item's own `⏰` time on its due day, or
    /// the caller's default hour when it only has a date.
    func reminderDate(defaultMinutes: Int) -> Date? {
        guard let dueDate else { return nil }
        let cal = Calendar.current
        let h = timeComponents?.hour ?? defaultMinutes / 60
        let m = timeComponents?.minute ?? defaultMinutes % 60
        return cal.date(bySettingHour: h, minute: m, second: 0, of: dueDate)
    }
}

/// ISO-week arithmetic in one place, so "this week" means the same thing for
/// bucketing, weekly routines and the Monday digest.
enum TodoClock {
    static var iso: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal
    }

    static func isSameISOWeek(_ a: Date, _ b: Date) -> Bool {
        let ca = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: a)
        let cb = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: b)
        return ca.yearForWeekOfYear == cb.yearForWeekOfYear && ca.weekOfYear == cb.weekOfYear
    }

    /// Next Monday strictly after `day` (or `day` itself at the given time when
    /// that moment is still ahead).
    static func nextMonday(after day: Date, atMinutes minutes: Int) -> Date? {
        let cal = iso
        var comps = DateComponents()
        comps.weekday = 2   // Monday in the ISO calendar's Gregorian weekday numbering
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        return cal.nextDate(after: day, matching: comps, matchingPolicy: .nextTime)
    }
}

struct Dashboard: Codable, Equatable {
    let version: Int
    let generated: String?
    let rocky: RockyNudge?
    var tasks: [DashboardTask]
    let agenda: [AgendaItem]
    let projects: [ProjectSummary]
    var market: [MarketItem]
    /// Schema v4 `todo` key (2026-09-28): Alp's own list from `Areas/To-Do.md`.
    var todo: [TodoItem]
    let todoFile: String?
    let companion: CompanionData
    var health: HealthToday
    /// Schema v3 `finance` key (2026-09-12); older dashboards lack it → nil.
    let finance: FinancePayload?
    /// Schema v5 `pocket` key (2026-10-14): time / place / your part for the
    /// next few days, from `Areas/Pocket.md`.
    var pocket: [PocketItem]
    let pocketFile: String?
    /// Schema v6 `pocket.facts` (2026-10-15): the undated must-remember bullets
    /// under `## Important`. Older payloads lack the key → [].
    var pocketFacts: [PocketFact]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        generated = try c.decodeIfPresent(String.self, forKey: .generated)
        rocky = try c.decodeIfPresent(RockyNudge.self, forKey: .rocky)
        tasks = try c.decodeIfPresent([DashboardTask].self, forKey: .tasks) ?? []
        agenda = try c.decodeIfPresent([AgendaItem].self, forKey: .agenda) ?? []
        projects = try c.decodeIfPresent([ProjectSummary].self, forKey: .projects) ?? []
        // Older dashboards (schema v1, pre-market-list) simply lack this key.
        market = try c.decodeIfPresent([MarketItem].self, forKey: .market) ?? []
        // Schema v4: `"todo": {"file": …, "items": […]}` — pre-To-Do dashboards lack it.
        let todoPayload = try c.decodeIfPresent(TodoPayload.self, forKey: .todo)
        todo = todoPayload?.items ?? []
        todoFile = todoPayload?.file
        // Schema v3 additions — pre-Companion/Health dashboards lack both keys.
        companion = try c.decodeIfPresent(CompanionData.self, forKey: .companion) ?? CompanionData()
        health = try c.decodeIfPresent(HealthToday.self, forKey: .health) ?? HealthToday()
        finance = try c.decodeIfPresent(FinancePayload.self, forKey: .finance)
        // Schema v5: `"pocket": {"file": …, "items": […]}`. Decoded with `try?` —
        // a malformed Pocket must never blank the whole dashboard.
        let pocketPayload = (try? c.decodeIfPresent(PocketPayload.self, forKey: .pocket)) ?? nil
        pocket = pocketPayload?.items ?? []
        pocketFile = pocketPayload?.file
        pocketFacts = pocketPayload?.facts ?? []
    }

    init(version: Int = 1, generated: String? = nil, rocky: RockyNudge? = nil,
         tasks: [DashboardTask] = [], agenda: [AgendaItem] = [], projects: [ProjectSummary] = [],
         market: [MarketItem] = [], todo: [TodoItem] = [], todoFile: String? = nil,
         companion: CompanionData = CompanionData(),
         health: HealthToday = HealthToday(), finance: FinancePayload? = nil,
         pocket: [PocketItem] = [], pocketFile: String? = nil, pocketFacts: [PocketFact] = []) {
        self.version = version; self.generated = generated; self.rocky = rocky
        self.tasks = tasks; self.agenda = agenda; self.projects = projects
        self.market = market; self.todo = todo; self.todoFile = todoFile
        self.companion = companion; self.health = health
        self.finance = finance
        self.pocket = pocket; self.pocketFile = pocketFile; self.pocketFacts = pocketFacts
    }

    /// Re-wrap for the encoder so the cache round-trips through the same
    /// `{"file", "items"}` shape CI writes.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(generated, forKey: .generated)
        try c.encodeIfPresent(rocky, forKey: .rocky)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(agenda, forKey: .agenda)
        try c.encode(projects, forKey: .projects)
        try c.encode(market, forKey: .market)
        try c.encode(TodoPayload(file: todoFile, items: todo), forKey: .todo)
        try c.encode(companion, forKey: .companion)
        try c.encode(health, forKey: .health)
        try c.encodeIfPresent(finance, forKey: .finance)
        try c.encode(PocketPayload(file: pocketFile, items: pocket, facts: pocketFacts), forKey: .pocket)
    }

    private enum CodingKeys: String, CodingKey {
        case version, generated, rocky, tasks, agenda, projects, market, todo, companion, health, finance, pocket
    }

    /// The wire shape of the `todo` key.
    struct TodoPayload: Codable {
        let file: String?
        let items: [TodoItem]
        init(file: String?, items: [TodoItem]) { self.file = file; self.items = items }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            items = try c.decodeIfPresent([TodoItem].self, forKey: .items) ?? []
        }
    }

    /// The wire shape of the `pocket` key.
    struct PocketPayload: Codable {
        let file: String?
        let items: [PocketItem]
        let facts: [PocketFact]
        init(file: String?, items: [PocketItem], facts: [PocketFact] = []) {
            self.file = file; self.items = items; self.facts = facts
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            // One bad item drops itself, not the list.
            items = (try? c.decodeIfPresent([Failable<PocketItem>].self, forKey: .items))?
                .compactMap(\.value) ?? []
            // Schema v6. Its own `try?`: a bad `facts` key must never drop the cards.
            facts = (try? c.decodeIfPresent([Failable<PocketFact>].self, forKey: .facts))?
                .compactMap(\.value) ?? []
        }
    }

    var generatedAt: Date? {
        guard let generated else { return nil }
        return ISO8601DateFormatter().date(from: generated)
    }

    func tasks(in bucket: TaskBucket) -> [DashboardTask] {
        tasks.filter { $0.bucket == bucket }
    }

    /// Today's screen shows only what's actionable now — overdue plus today.
    var todayTasks: [DashboardTask] { tasks(in: .today) }
    var overdueTasks: [DashboardTask] { tasks(in: .overdue) }
    var upcomingTasks: [DashboardTask] { tasks(in: .upcoming) }

    var isEmpty: Bool { tasks.isEmpty && agenda.isEmpty && projects.isEmpty && rocky == nil }
}

// MARK: - Pocket (schema v5)

/// Decodes to nil instead of throwing, so one malformed element can't sink an array.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// One thing to be at or do: the vital facts only. Built vault-side from
/// `Areas/Pocket.md` — a Rocky-written card, a mirrored calendar event, or
/// both merged. Read-only on the phone.
struct PocketItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let date: String            // YYYY-MM-DD
    let start: String?          // HH:MM; nil = all day
    let end: String?
    let title: String
    let place: String?
    let part: String?           // 👉 what Alp has to do
    let bring: String?          // 🎒
    let notes: [String]         // 📝
    let source: String?         // 🔗 vault note name
    let origin: String          // card | calendar | both

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        place = try c.decodeIfPresent(String.self, forKey: .place)
        part = try c.decodeIfPresent(String.self, forKey: .part)
        bring = try c.decodeIfPresent(String.self, forKey: .bring)
        notes = (try? c.decodeIfPresent([String].self, forKey: .notes)) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "card"
    }

    init(id: String, date: String, start: String? = nil, end: String? = nil, title: String,
         place: String? = nil, part: String? = nil, bring: String? = nil, notes: [String] = [],
         source: String? = nil, origin: String = "card") {
        self.id = id; self.date = date; self.start = start; self.end = end; self.title = title
        self.place = place; self.part = part; self.bring = bring; self.notes = notes
        self.source = source; self.origin = origin
    }

    var isAllDay: Bool { startDate == nil }

    /// A thin card is a calendar event Rocky has nothing to add to.
    var hasDetails: Bool { part != nil || bring != nil || !notes.isEmpty }

    /// Midnight of `date`, device time zone.
    var day: Date? { DateFormatter.vaultDay.date(from: date) }

    var startDate: Date? { PocketClock.at(start, on: day) }

    /// When the item stops mattering: its end time; start + 1 h when no end is
    /// given; for an all-day item, 05:00 the next morning — the vault day.
    var overAt: Date? {
        guard let day else { return nil }
        let cal = Calendar.current
        guard let startDate else {
            return cal.date(byAdding: .hour, value: 24 + PocketClock.dayStartHour, to: day)
        }
        if var endDate = PocketClock.at(end, on: day) {
            if endDate <= startDate { endDate = cal.date(byAdding: .day, value: 1, to: endDate) ?? endDate }
            return endDate
        }
        return cal.date(byAdding: .hour, value: 1, to: startDate)
    }

    func isOver(now: Date = Date()) -> Bool {
        guard let overAt else { return true }      // undecodable date: never show
        return overAt <= now
    }

    /// `14:15–15:45`, `14:15`, or `All day`.
    var timeLabel: String {
        guard let start, startDate != nil else { return "All day" }
        if let end, PocketClock.at(end, on: day) != nil { return "\(start)–\(end)" }
        return start
    }
}

/// One bullet under `## Important` in `Areas/Pocket.md` — an undated
/// must-remember thing ("Door code B-Bau — 4417"). Plain bullet, not a
/// checkbox. `id` is a hash of `text`, so an edit changes it vault-side; the
/// phone keeps the old id on its optimistic copy until CI re-issues the list.
struct PocketFact: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let text: String            // everything after the bullet
    let label: String
    let detail: String          // "" when the bullet has no " — detail"
    let file: String
    let line: Int               // 1-based real file line; a hint only
    let raw: String             // the exact bullet line

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        let parts = Self.split(text)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? parts.label
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? parts.detail
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? Self.newLine(label: label, detail: detail)
    }

    init(id: String, label: String, detail: String = "", file: String, line: Int = 0, raw: String? = nil) {
        let l = Self.cleanLabel(label), d = Self.clean(detail)
        self.id = id; self.label = l; self.detail = d
        self.text = d.isEmpty ? l : "\(l)\(Self.separator)\(d)"
        self.file = file; self.line = line
        self.raw = raw ?? Self.newLine(label: l, detail: d)
    }

    // The text rules live here, not in `FactEditor` (TodoEditors.swift, which
    // delegates), so this file stays compilable on its own — the expense
    // checks build it without the editors.
    static let separator = " — "

    /// One line of text: newlines and tabs become spaces, runs of blanks collapse.
    static func clean(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A label must not contain the separator, or the next parse would cut it in two.
    static func cleanLabel(_ s: String) -> String {
        clean(s).replacingOccurrences(of: separator, with: " – ")
    }

    /// `"Door code — 4417"` → ("Door code", "4417"); no separator → detail "".
    static func split(_ text: String) -> (label: String, detail: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: separator) else { return (t, "") }
        return (String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// The vault line for a fact: `- label — detail`, detail optional.
    static func newLine(label: String, detail: String) -> String {
        let l = cleanLabel(label), d = clean(detail)
        return d.isEmpty ? "- \(l)" : "- \(l)\(separator)\(d)"
    }
}

enum PocketClock {
    /// Alp's day runs 05:00 → 05:00 (vault rule): at 01:00 on the 15th, an item
    /// on the 15th is still "Tomorrow".
    static let dayStartHour = 5

    static func at(_ hhmm: String?, on day: Date?) -> Date? {
        guard let hhmm, let day else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)
    }

    /// Midnight of the vault day `now` falls in.
    static func vaultDay(of now: Date) -> Date {
        let cal = Calendar.current
        let shifted = cal.date(byAdding: .hour, value: -dayStartHour, to: now) ?? now
        return cal.startOfDay(for: shifted)
    }

    static func label(for day: Date, now: Date) -> String {
        let cal = Calendar.current
        let offset = cal.dateComponents([.day], from: vaultDay(of: now), to: cal.startOfDay(for: day)).day ?? 0
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.setLocalizedDateFormatFromTemplate("EEE d.M")
            return f.string(from: day)
        }
    }

    /// Items still ahead, grouped by day; all-day items first, then by start.
    static func groups(_ items: [PocketItem], now: Date = Date()) -> [(label: String, items: [PocketItem])] {
        let live = items.filter { !$0.isOver(now: now) && $0.day != nil }
        let byDay = Dictionary(grouping: live) { $0.date }
        return byDay.keys.sorted().compactMap { key in
            guard let rows = byDay[key], let day = rows.first?.day else { return nil }
            let sorted = rows.sorted { a, b in
                switch (a.startDate, b.startDate) {
                case (nil, nil): return a.title < b.title
                case (nil, _): return true
                case (_, nil): return false
                case let (x?, y?): return x == y ? a.title < b.title : x < y
                }
            }
            return (label(for: day, now: now), sorted)
        }
    }
}

extension DateFormatter {
    /// `YYYY-MM-DD`, the vault's canonical day format (daily notes, 📅 markers).
    static let vaultDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
