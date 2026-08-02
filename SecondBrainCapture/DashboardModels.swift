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

struct Dashboard: Codable, Equatable {
    let version: Int
    let generated: String?
    let rocky: RockyNudge?
    var tasks: [DashboardTask]
    let agenda: [AgendaItem]
    let projects: [ProjectSummary]
    var market: [MarketItem]

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
    }

    init(version: Int = 1, generated: String? = nil, rocky: RockyNudge? = nil,
         tasks: [DashboardTask] = [], agenda: [AgendaItem] = [], projects: [ProjectSummary] = [],
         market: [MarketItem] = []) {
        self.version = version; self.generated = generated; self.rocky = rocky
        self.tasks = tasks; self.agenda = agenda; self.projects = projects
        self.market = market
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
