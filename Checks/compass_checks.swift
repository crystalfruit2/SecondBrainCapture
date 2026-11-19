// Checks for Compass (schema v7): decoding and the cache round trip, tolerant
// decoding of older/broken payloads, the "Now" picker on the 05:00 vault-day
// clock, the log line and where it lands, status chips, the optimistic
// doneMin bump and its replay over a fresh dashboard. No Xcode project,
// simulator or network needed — run from the repo root:
//
//   S=SecondBrainCapture
//   swiftc -parse-as-library $S/DashboardModels.swift $S/CompassModels.swift $S/TodoNotifier.swift \
//          $S/TodoEditors.swift $S/GitHubService.swift $S/GitHubService+Dashboard.swift \
//          Checks/compass_checks.swift -o /tmp/compass_checks
//   /tmp/compass_checks [path/to/real/dashboard.json]   (with or without a compass key)
//
// Contract with the vault: `second_brain/.claude/scripts/compass.py` writes the
// `compass` key; its shape is pinned by `Checks/fixtures/compass-payload.json`
// (a full dashboard, compass computed for Mon 2026-11-09). After changing the
// payload shape, regenerate the fixture and decode it here.

import Foundation

@main
enum CompassChecks {
    static var failures = 0
    static var passed = 0

    static func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond { passed += 1; print("ok   \(name)") }
        else { failures += 1; print("FAIL \(name) \(detail())") }
    }

    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func decode(_ json: String) throws -> Dashboard {
        try JSONDecoder().decode(Dashboard.self, from: Data(json.utf8))
    }

    static func describe(_ n: CompassNow) -> String {
        switch n {
        case .current(let s): return "now \(s.start) \(s.title)"
        case .next(let s): return "next \(s.start) \(s.title)"
        case .done: return "done"
        }
    }

    static func main() {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        // 1. The fixture decodes, and the cache keeps it.
        var payload: CompassPayload!
        do {
            let data = try Data(contentsOf: here.appendingPathComponent("fixtures/compass-payload.json"))
            let board = try JSONDecoder().decode(Dashboard.self, from: data)
            check("fixture: version 7, compass present", board.version == 7 && board.compass != nil)
            payload = board.compass
            check("fixture: counts", payload.areas.count == 9 && payload.fixed.count == 3 && payload.blocks.count == 5
                  && payload.top.count == 6 && payload.letGo.count == 3,
                  "\(payload.areas.count)/\(payload.fixed.count)/\(payload.blocks.count)/\(payload.top.count)/\(payload.letGo.count)")
            let apc = payload.area("apc")
            check("fixture: apc fields", apc?.emoji == "🎛️" && apc?.targetMin == 240 && apc?.floorMin == 120
                  && apc?.statusKind == .belowFloor && apc?.next == "rework Wed lecture (MPC intro)" && apc?.deadline == nil,
                  "\(String(describing: apc))")
            check("fixture: deadline label", payload.area("summer27")?.deadlineLabel == "EPFL closes 29.11")
            check("fixture: capacity", payload.capacity?.freeMin == 1860 && payload.capacity?.targetMin == 1740
                  && payload.capacity?.remainingFreeMin == 1500)
            check("fixture: top item", payload.top.first?.score == 84 && payload.top.first?.due == "2026-11-11"
                  && payload.top.first?.why.count == 2)
            check("fixture: generatedAt parses", payload.generatedAt != nil)
            check("fixture: other keys untouched", board.todo.count == 3 && board.projects.count == 1)

            let again = try JSONDecoder().decode(Dashboard.self, from: JSONEncoder().encode(board))
            check("round trip keeps compass", again.compass == board.compass && again.todo == board.todo)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(board)) as? [String: Any]
            check("encoded as top-level compass", (json?["compass"] as? [String: Any])?["file"] as? String == "Areas/Compass.md")
        } catch {
            check("fixture decodes", false, "\(error)")
            print("\n\(passed) passed, \(failures) failed")
            exit(1)
        }

        // 2. Absent or broken compass never blanks the dashboard.
        do {
            let pocket = try JSONDecoder().decode(Dashboard.self,
                from: Data(contentsOf: here.appendingPathComponent("fixtures/pocket-payload.json")))
            check("pocket fixture (v6): compass nil", pocket.compass == nil && pocket.pocket.count == 5)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pocket)) as? [String: Any]
            check("nil compass not encoded", encoded?["compass"] == nil)
            let wrong = try decode(#"{"version":7,"todo":{"file":"Areas/To-Do.md","items":[]},"compass":5}"#)
            check("wrong-type compass → nil", wrong.compass == nil && wrong.todoFile == "Areas/To-Do.md")
            let noFile = try decode(#"{"version":7,"compass":{"date":"2026-11-09","areas":[],"blocks":[],"top":[]}}"#)
            check("compass without file → nil", noFile.compass == nil)
            let thin = try decode(#"{"version":7,"compass":{"file":"Areas/Compass.md","date":"2026-11-09","areas":[{"id":"x"}],"blocks":[{"start":"10:00","end":"11:30","area":"x"}],"top":[{"title":"T"}],"capacity":null,"headline":null,"extra":{"a":1}}}"#)
            let c = thin.compass
            check("thin compass decodes with defaults", c?.logHeading == "Log" && c?.week == nil && c?.capacity == nil
                  && c?.fixed.isEmpty == true && c?.letGo.isEmpty == true && c?.waiting == nil, "\(String(describing: c))")
            let x = c?.areas.first
            check("thin area defaults", x?.name == "x" && x?.emoji == "•" && x?.targetMin == 0 && x?.statusKind == .idle
                  && x?.next == nil, "\(String(describing: x))")
            check("block minutes derived from times", c?.blocks.first?.minutes == 90 && c?.blocks.first?.why == [])
            check("item id falls back to title", c?.top.first?.id == "T" && c?.top.first?.kind == "task")
            let messy = try decode(#"{"version":7,"compass":{"file":"F","date":"2026-11-09","areas":[{"id":"a","targetMin":240.0,"doneMin":"30"},{"name":"no id"},7],"blocks":[{"title":"no times"}],"top":[]}}"#)
            check("one bad area dropped, numbers tolerant", messy.compass?.areas.map(\.id) == ["a"]
                  && messy.compass?.areas.first?.targetMin == 240 && messy.compass?.areas.first?.doneMin == 30
                  && messy.compass?.blocks.isEmpty == true, "\(String(describing: messy.compass))")
        } catch {
            check("tolerant decoding", false, "\(error)")
        }
        if CommandLine.arguments.count > 1 {
            do {
                let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
                let real = try JSONDecoder().decode(Dashboard.self, from: raw)
                // Either an older dashboard (no key → nil) or the vault engine's real
                // output, which must decode in full (no element silently dropped).
                let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
                if let c = json?["compass"] as? [String: Any] {
                    let n = { (k: String) in (c[k] as? [Any])?.count ?? 0 }
                    let got = real.compass
                    check("real vault compass decodes in full (v\(real.version))", got != nil
                          && got?.areas.count == n("areas") && got?.blocks.count == n("blocks")
                          && got?.fixed.count == n("fixed") && got?.top.count == n("top") && got?.letGo.count == n("letGo"),
                          "\(String(describing: got?.areas.count)) areas vs \(n("areas"))")
                    check("real vault compass round-trips", (try? JSONDecoder().decode(Dashboard.self,
                          from: JSONEncoder().encode(real)))?.compass == real.compass)
                } else {
                    check("real dashboard without compass decodes (v\(real.version))", real.compass == nil && !real.projects.isEmpty)
                }
            } catch {
                check("real dashboard decodes", false, "\(error)")
            }
        }

        // 3. The vault-day clock and the Now picker (payload computed for Mon 09.11).
        check("clock: 14:15 → 855, 01:30 → 25:30", CompassClock.minutes("14:15") == 855 && CompassClock.minutes("01:30") == 1530)
        check("clock: bad time → nil", CompassClock.minutes("25:00") == nil && CompassClock.minutes("9") == nil)
        check("clock: duration over midnight", CompassClock.duration("23:30", "00:30") == 60)
        check("today at 04:59 is still yesterday", CompassClock.today(at(2026, 11, 10, 4, 59)) == "2026-11-09"
              && CompassClock.today(at(2026, 11, 10, 5, 0)) == "2026-11-10")
        check("nowMinutes after midnight", CompassClock.nowMinutes(at(2026, 11, 10, 1, 0)) == 25 * 60)
        check("timeline merges chronologically", payload.timeline.map(\.start)
              == ["08:30", "10:15", "13:15", "14:15", "16:00", "17:30", "18:15", "20:00"],
              "\(payload.timeline.map(\.start))")

        let cases: [(Date, String)] = [
            (at(2026, 11, 9, 7, 0), "next 08:30 A&PC V+Ü · HS 0446"),
            (at(2026, 11, 9, 9, 0), "now 08:30 A&PC V+Ü · HS 0446"),
            (at(2026, 11, 9, 10, 15), "now 10:15 A&PC: rework Wed lecture (MPC intro)"),
            (at(2026, 11, 9, 11, 45), "next 13:15 Host-lab list: 2 more names"),     // end is exclusive
            (at(2026, 11, 9, 12, 45), "next 13:15 Host-lab list: 2 more names"),
            (at(2026, 11, 9, 18, 30), "now 18:15 🏐 Volleyball, Aueparkhalle"),
            (at(2026, 11, 9, 21, 30), "done"),
            (at(2026, 11, 10, 1, 0), "done"),                                      // after midnight, same vault day
            (at(2026, 11, 10, 5, 0), "done"),                                      // new vault day: plan is old
            (at(2026, 11, 8, 20, 0), "next 08:30 A&PC V+Ü · HS 0446"),             // computed ahead for tomorrow
        ]
        for (when, want) in cases {
            let got = describe(CompassClock.pick(payload, now: when))
            check("pick at \(DateFormatter.localizedString(from: when, dateStyle: .short, timeStyle: .short))", got == want, got)
        }
        check("stale flag", !CompassClock.isStale(payload, now: at(2026, 11, 10, 4, 59))
              && CompassClock.isStale(payload, now: at(2026, 11, 10, 5, 0)))

        let night = CompassPayload(file: "F", date: "2026-11-09", areas: [],
                                   blocks: [CompassBlock(start: "23:30", end: "00:30", area: "rocky", title: "Late build")])
        check("block across midnight: live at 00:15", describe(CompassClock.pick(night, now: at(2026, 11, 10, 0, 15))) == "now 23:30 Late build")
        check("block across midnight: next at 23:00", describe(CompassClock.pick(night, now: at(2026, 11, 9, 23, 0))) == "next 23:30 Late build")
        check("block across midnight: done at 00:30", CompassClock.pick(night, now: at(2026, 11, 10, 0, 30)) == .done)
        let empty = CompassPayload(file: "F", date: "2026-11-09")
        check("empty plan → done", CompassClock.pick(empty, now: at(2026, 11, 9, 9, 0)) == .done)

        // Done buttons: sport once started, blocks once ended.
        let sport = payload.timeline.first { $0.kind == "sport" }!
        let apcBlock = payload.timeline.first { !$0.isFixed && $0.area == "apc" }!
        let lecture = payload.timeline.first { $0.isFixed && $0.kind == "class" }!
        check("done: sport hidden before start", !CompassClock.canMarkDone(sport, payload: payload, now: at(2026, 11, 9, 18, 0)))
        check("done: sport shown once started", CompassClock.canMarkDone(sport, payload: payload, now: at(2026, 11, 9, 18, 20)))
        check("done: block only after its end", !CompassClock.canMarkDone(apcBlock, payload: payload, now: at(2026, 11, 9, 11, 0))
              && CompassClock.canMarkDone(apcBlock, payload: payload, now: at(2026, 11, 9, 11, 45)))
        check("done: never on a class", !CompassClock.canMarkDone(lecture, payload: payload, now: at(2026, 11, 9, 23, 0)))

        // 4. The log line, exactly as the contract writes it, and where it lands.
        check("line: default note", CompassLog.line(date: "2026-11-09", areaId: "apc", minutes: 60, note: "")
              == "- 2026-11-09 · apc · 60m · from phone")
        check("line: own note", CompassLog.line(date: "2026-11-09", areaId: "sport", minutes: 90, note: " volleyball ✓ ")
              == "- 2026-11-09 · sport · 90m · volleyball ✓")
        check("line: one line only", CompassLog.line(date: "2026-11-09", areaId: "rl", minutes: 45, note: "a\nb\tc")
              == "- 2026-11-09 · rl · 45m · a b c")
        check("line: minutes at least 1", CompassLog.line(date: "2026-11-09", areaId: "rl", minutes: 0, note: "x").contains(" · 1m · "))
        let log = PendingCompassLog(file: "Areas/Compass.md", heading: CompassLog.heading("Log"), date: "2026-11-09",
                                    areaId: "apc", minutes: 60, note: "")
        check("pending log line + heading", log.line == "- 2026-11-09 · apc · 60m · from phone" && log.heading == "## Log")
        check("heading normalised", CompassLog.heading("## Log ") == "## Log" && CompassLog.heading("") == "## Log")
        let note = "# 🧭 Compass\n\n## Matching\n\n| a |\n\n## Log\n- 2026-11-08 · opt · 30m · from phone\n"
        let added = TodoFileEditor.insert(log.line, under: log.heading, in: note)
        check("insert: joins the end of ## Log", added == note + log.line + "\n", added)
        let withTail = "## Log\n- 2026-11-08 · opt · 30m · x\n\n## Later\n"
        check("insert: before the next heading's blank line",
              TodoFileEditor.insert(log.line, under: "## Log", in: withTail)
              == "## Log\n- 2026-11-08 · opt · 30m · x\n\(log.line)\n\n## Later\n")
        let fresh = TodoFileEditor.insert(log.line, under: log.heading, in: CompassLog.template)
        check("404 template: Compass-shaped, line under ## Log",
              fresh.hasSuffix("## Log\n\(log.line)") && fresh.contains("# 🧭 Compass") && !fresh.contains("## To do"), fresh)
        check("log codable", (try? JSONDecoder().decode(PendingCompassLog.self, from: JSONEncoder().encode(log))) == log)

        // 5. Status → chip.
        let chips = CompassStatus.allCases.map { "\($0.rawValue)=\($0.label)" }
        check("chip labels", chips == ["ahead=ahead", "on-pace=on pace", "behind=behind", "below-floor=below floor", "idle=idle"],
              "\(chips)")
        check("chip tones", CompassStatus(raw: "ahead").tone == .good && CompassStatus(raw: "on-pace").tone == .neutral
              && CompassStatus(raw: "behind").tone == .warn && CompassStatus(raw: "below-floor").tone == .bad
              && CompassStatus(raw: "idle").tone == .muted)
        check("unknown status → on pace", CompassStatus(raw: "sideways") == .onPace)

        // 6. Display strings.
        let rl = payload.area("rl")!
        check("progress text", CompassFormat.progress(rl) == "1 / 4 h" && CompassFormat.progress(payload.area("opt")!) == "2.5 / 4 h",
              CompassFormat.progress(payload.area("opt")!))
        check("hours rounding", CompassFormat.hours(20) == "0.3" && CompassFormat.hours(0) == "0" && CompassFormat.hours(1035) == "17.3")
        check("capacity line", CompassFormat.capacity(payload.capacity!) == "31 h free after classes · targets ask 29 h",
              CompassFormat.capacity(payload.capacity!))
        check("capacity warning", !payload.capacity!.isOverbooked && CompassCapacity(freeMin: 600, targetMin: 900).isOverbooked)
        check("bar fractions", abs(payload.area("opt")!.progress - 0.625) < 1e-9 && payload.area("opt")!.floorFraction == 0.5
              && payload.area("rocky")!.progress == 1 && payload.area("admin")!.progress == 0)
        check("emoji: leading one dropped", CompassFormat.dropLeadingEmoji("🎛️ A&PC: notes") == "A&PC: notes"
              && CompassFormat.dropLeadingEmoji("🇨🇭 Swiss") == "Swiss" && CompassFormat.dropLeadingEmoji("📱 Nudge") == "Nudge",
              CompassFormat.dropLeadingEmoji("🎛️ A&PC: notes"))
        check("emoji: plain titles untouched", CompassFormat.dropLeadingEmoji("RL HW3 Task 1") == "RL HW3 Task 1"
              && CompassFormat.dropLeadingEmoji("1. step") == "1. step" && CompassFormat.dropLeadingEmoji("🏐") == "🏐"
              && CompassFormat.dropLeadingEmoji("#tag") == "#tag")
        check("short day", CompassFormat.shortDay("2026-11-11") == "Wed 11.11", CompassFormat.shortDay("2026-11-11"))

        // 7. Optimistic doneMin bump.
        let bumped = CompassLog.bump(payload, areaId: "apc", minutes: 60)
        check("bump: +60 done and logged", bumped.area("apc")?.doneMin == 60 && bumped.area("apc")?.loggedMin == 60)
        check("bump: still below floor at 60/120", bumped.area("apc")?.statusKind == .belowFloor)
        let twice = CompassLog.bump(bumped, areaId: "apc", minutes: 60)
        check("bump: crossing the floor → behind", twice.area("apc")?.doneMin == 120 && twice.area("apc")?.statusKind == .behind)
        let full = CompassLog.bump(payload, areaId: "rl", minutes: 180)
        check("bump: reaching target → ahead", full.area("rl")?.doneMin == 240 && full.area("rl")?.statusKind == .ahead)
        check("bump: other areas untouched", bumped.area("rl") == payload.area("rl") && bumped.blocks == payload.blocks)
        check("bump: unknown area / zero minutes = no-op", CompassLog.bump(payload, areaId: "nope", minutes: 60) == payload
              && CompassLog.bump(payload, areaId: "apc", minutes: 0) == payload)

        // 8. Replay over a fresh dashboard (generated 2026-11-09 07:12 +01:00).
        let gen = payload.generatedAt!
        var unsynced = PendingCompassLog(file: "F", heading: "## Log", date: "2026-11-09", areaId: "apc", minutes: 30, note: "")
        check("replay: unsynced counts", CompassLog.applying([unsynced], to: payload).area("apc")?.doneMin == 30)
        unsynced.syncedAt = gen.addingTimeInterval(-60)
        check("replay: synced before the build → already counted", CompassLog.applying([unsynced], to: payload) == payload)
        unsynced.syncedAt = gen.addingTimeInterval(60)
        check("replay: synced after the build → still added", CompassLog.applying([unsynced], to: payload).area("apc")?.doneMin == 30)
        let lastWeek = PendingCompassLog(file: "F", heading: "## Log", date: "2026-11-08", areaId: "apc", minutes: 30, note: "")
        check("replay: other ISO week ignored", CompassLog.isoWeek(of: "2026-11-08") == "2026-W45"
              && CompassLog.applying([lastWeek], to: payload) == payload)
        check("iso week", CompassLog.isoWeek(of: "2026-11-09") == "2026-W46" && CompassLog.isoWeek(of: "2027-01-01") == "2026-W53")

        print("\n\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
