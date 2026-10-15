// Checks for the Pocket tab: decoding (schema v5 and older dashboards), the
// 05:00 vault-day clock, grouping, and reminder times. No Xcode project,
// simulator or network needed — run from the repo root:
//
//   S=SecondBrainCapture
//   swiftc -parse-as-library $S/DashboardModels.swift $S/TodoNotifier.swift \
//          Checks/pocket_checks.swift -o /tmp/pocket_checks
//   /tmp/pocket_checks [path/to/older-dashboard.json]
//
// Contract with the vault: `Checks/fixtures/pocket-payload.json` is real output
// of `second_brain/.claude/scripts/build_dashboard.py`'s `parse_pocket` (three
// cards merged with a three-event calendar block, today = 2026-10-14). After
// changing the payload shape, regenerate it there and decode it here.

import Foundation

@main
enum PocketChecks {
    static var failures = 0
    static var passed = 0

    static func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond { passed += 1; print("ok   \(name)") }
        else { failures += 1; print("FAIL \(name) \(detail())") }
    }

    /// Local wall-clock moment, like the phone sees it.
    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func decode(_ json: String) throws -> Dashboard {
        try JSONDecoder().decode(Dashboard.self, from: Data(json.utf8))
    }

    static func main() {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        // 1. The vault's real output decodes, merged fields intact.
        do {
            let data = try Data(contentsOf: here.appendingPathComponent("fixtures/pocket-payload.json"))
            let board = try JSONDecoder().decode(Dashboard.self, from: data)
            check("fixture: 5 items", board.pocket.count == 5, "\(board.pocket.count)")
            let fb16 = board.pocket.first { $0.title == "FB16 Studienservice" }
            check("fixture: FB16 merged", fb16?.origin == "both" && fb16?.end == "10:20"
                  && fb16?.place == "Wilhelmshöher Allee 73, Raum 1324" && fb16?.bring == "Screenshot + signed LA",
                  "\(String(describing: fb16))")
            let rl = board.pocket.first { $0.title.hasPrefix("RL") }
            check("fixture: RL fields", rl?.part == "Be in the room at 14:15" && rl?.notes.count == 1
                  && rl?.source == "Kassel-Learning-Agreement", "\(String(describing: rl))")
            check("fixture: meeting link", board.pocket.contains { $0.place == "Online · zoom.us" })
            check("fixture: file", board.pocketFile != nil)

            // Cache round trip keeps Pocket (encode(to:) must carry it).
            let again = try JSONDecoder().decode(Dashboard.self, from: JSONEncoder().encode(board))
            check("round trip keeps pocket", again.pocket == board.pocket && again.pocketFile == board.pocketFile)
        } catch {
            check("fixture decodes", false, "\(error)")
        }

        // 2. Older dashboards, and a broken Pocket, never blank the dashboard.
        do {
            let v4 = try decode(#"{"version":4,"tasks":[],"todo":{"file":"Areas/To-Do.md","items":[]}}"#)
            check("v4 without pocket", v4.pocket.isEmpty && v4.version == 4)
            let wrongType = try decode(#"{"version":5,"pocket":[1,2,3]}"#)
            check("pocket of wrong type ignored", wrongType.pocket.isEmpty)
            let oneBad = try decode(#"{"version":5,"pocket":{"file":"Areas/Pocket.md","items":[{"id":"a","date":"2026-10-15","title":"Good"},{"title":"no id or date"}]}}"#)
            check("one bad item dropped, rest kept", oneBad.pocket.map(\.title) == ["Good"], "\(oneBad.pocket)")
        } catch {
            check("tolerant decoding", false, "\(error)")
        }
        if CommandLine.arguments.count > 1 {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
                let real = try JSONDecoder().decode(Dashboard.self, from: data)
                check("real older dashboard decodes (v\(real.version))", real.pocket.isEmpty && !real.projects.isEmpty)
            } catch {
                check("real older dashboard decodes", false, "\(error)")
            }
        }

        // 3. When an item is over.
        let timed = PocketItem(id: "t", date: "2026-10-15", start: "14:15", end: "15:45", title: "RL")
        check("timed: live before end", !timed.isOver(now: at(2026, 10, 15, 15, 44)))
        check("timed: over at end", timed.isOver(now: at(2026, 10, 15, 15, 45)))
        let open = PocketItem(id: "o", date: "2026-10-15", start: "09:50", title: "FB16")
        check("no end: live for an hour", !open.isOver(now: at(2026, 10, 15, 10, 49)) && open.isOver(now: at(2026, 10, 15, 10, 50)))
        let allDay = PocketItem(id: "a", date: "2026-10-15", title: "Deadline")
        check("all day: live until 05:00 next day", !allDay.isOver(now: at(2026, 10, 16, 4, 59)) && allDay.isOver(now: at(2026, 10, 16, 5, 0)))
        let late = PocketItem(id: "l", date: "2026-10-15", start: "23:00", end: "01:00", title: "Night")
        check("end past midnight", !late.isOver(now: at(2026, 10, 16, 0, 30)))
        let junk = PocketItem(id: "j", date: "15.10.2026", title: "Bad date")
        check("bad date never shows", junk.isOver(now: at(2026, 10, 1, 0)))
        check("labels", timed.timeLabel == "14:15–15:45" && open.timeLabel == "09:50" && allDay.timeLabel == "All day")

        // 4. Grouping follows the 05:00 vault day.
        let items = [timed, open, allDay, PocketItem(id: "v", date: "2026-10-16", start: "18:15", title: "Volleyball")]
        let atOne = PocketClock.groups(items, now: at(2026, 10, 15, 1, 0))
        check("01:00 on the 15th: the 15th is Tomorrow", atOne.first?.label == "Tomorrow", "\(atOne.map(\.label))")
        let atSix = PocketClock.groups(items, now: at(2026, 10, 15, 6, 0))
        check("06:00: Today, Tomorrow", atSix.map(\.label) == ["Today", "Tomorrow"], "\(atSix.map(\.label))")
        check("all-day first, then by start", atSix.first?.items.map(\.title) == ["Deadline", "FB16", "RL"],
              "\(String(describing: atSix.first?.items.map(\.title)))")
        let evening = PocketClock.groups(items, now: at(2026, 10, 15, 16, 0))
        check("finished items drop off", evening.first?.items.map(\.title) == ["Deadline"],
              "\(String(describing: evening.first?.items.map(\.title)))")
        let later = PocketClock.groups([PocketItem(id: "w", date: "2026-10-19", start: "14:15", title: "PRML")],
                                       now: at(2026, 10, 15, 6, 0))
        check("later days get a weekday label", later.first?.label.hasPrefix("Mon") == true, "\(later.map(\.label))")

        // 5. Reminders: 30 min before, only when still ahead, soonest first.
        let fires = TodoNotifier.pocketReminders(items, now: at(2026, 10, 15, 9, 25))
        check("reminder ids", fires.map(\.item.id) == ["t", "v"], "\(fires.map(\.item.id))")
        check("reminder at start − 30", fires.first?.fire == at(2026, 10, 15, 13, 45))
        check("all-day gets no reminder", !fires.contains { $0.item.id == "a" })

        print("\n\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
