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

/// Read-only mirror of what `/finance` keeps in the vault (schema v3 `finance`
/// key, generated by `build_dashboard.py:parse_finance`). Faz 0 contract: the
/// phone shows data and the record, never an order.
struct FinancePayload: Codable, Equatable {
    let sicil: [SicilRow]          // oldest → newest, ≤ 26 rows
    let sicilColumns: [String]
    let blocks: [String: String]   // record / rules / calendar markdown, each ≤ 2000 chars
    let brief: FinanceBrief?
    let source: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sicil = try c.decodeIfPresent([SicilRow].self, forKey: .sicil) ?? []
        sicilColumns = try c.decodeIfPresent([String].self, forKey: .sicilColumns) ?? []
        blocks = try c.decodeIfPresent([String: String].self, forKey: .blocks) ?? [:]
        brief = try c.decodeIfPresent(FinanceBrief.self, forKey: .brief)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    init(sicil: [SicilRow] = [], sicilColumns: [String] = [], blocks: [String: String] = [:],
         brief: FinanceBrief? = nil, source: String? = nil) {
        self.sicil = sicil; self.sicilColumns = sicilColumns; self.blocks = blocks; self.brief = brief; self.source = source
    }

    var latest: SicilRow? { sicil.last }
    var newestFirst: [SicilRow] { sicil.reversed() }
    var isEmpty: Bool { sicil.isEmpty && blocks.isEmpty && brief == nil }
}

struct Dashboard: Codable, Equatable {
    let version: Int
    let generated: String?
    let rocky: RockyNudge?
    var tasks: [DashboardTask]
    let agenda: [AgendaItem]
    let projects: [ProjectSummary]
    var market: [MarketItem]
    let companion: CompanionData
    var health: HealthToday
    /// Schema v3 `finance` key (2026-09-12); older dashboards lack it → nil.
    let finance: FinancePayload?

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
        // Schema v3 additions — pre-Companion/Health dashboards lack both keys.
        companion = try c.decodeIfPresent(CompanionData.self, forKey: .companion) ?? CompanionData()
        health = try c.decodeIfPresent(HealthToday.self, forKey: .health) ?? HealthToday()
        finance = try c.decodeIfPresent(FinancePayload.self, forKey: .finance)
    }

    init(version: Int = 1, generated: String? = nil, rocky: RockyNudge? = nil,
         tasks: [DashboardTask] = [], agenda: [AgendaItem] = [], projects: [ProjectSummary] = [],
         market: [MarketItem] = [], companion: CompanionData = CompanionData(),
         health: HealthToday = HealthToday(), finance: FinancePayload? = nil) {
        self.version = version; self.generated = generated; self.rocky = rocky
        self.tasks = tasks; self.agenda = agenda; self.projects = projects
        self.market = market; self.companion = companion; self.health = health
        self.finance = finance
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
