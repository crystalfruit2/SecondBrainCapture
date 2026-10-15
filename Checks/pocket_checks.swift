// Checks for the Pocket tab: decoding (schema v5/v6 and older dashboards), the
// 05:00 vault-day clock, grouping, reminder times, and the "Important" facts
// (decode, cache round trip, and the pure line editors). No Xcode project,
// simulator or network needed — run from the repo root:
//
//   S=SecondBrainCapture
//   swiftc -parse-as-library $S/DashboardModels.swift $S/TodoNotifier.swift \
//          $S/TodoEditors.swift $S/GitHubService.swift $S/GitHubService+Dashboard.swift \
//          Checks/pocket_checks.swift -o /tmp/pocket_checks
//   /tmp/pocket_checks [path/to/older-dashboard.json]
//
// Contract with the vault: `Checks/fixtures/pocket-payload.json` is real output
// of `second_brain/.claude/scripts/build_dashboard.py`'s `parse_pocket`: the
// five cards (three cards merged with a three-event calendar block, today =
// 2026-10-14) plus `facts` from `parse_pocket_facts` run on a temp vault whose
// `## Important` had five bullets (version 6). After changing the payload
// shape, regenerate it there and decode it here.

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

    // MARK: - Important facts (schema v6)

    static func importantFacts(_ here: URL) {
        // Decode the vault's real output.
        do {
            let data = try Data(contentsOf: here.appendingPathComponent("fixtures/pocket-payload.json"))
            let board = try JSONDecoder().decode(Dashboard.self, from: data)
            check("facts: version 6, 5 facts, cards untouched", board.version == 6
                  && board.pocketFacts.count == 5 && board.pocket.count == 5,
                  "\(board.pocketFacts.count) facts, \(board.pocket.count) items")
            let door = board.pocketFacts.first
            check("facts: first fact fields", door?.id == "1d7c7096" && door?.label == "Door code B-Bau"
                  && door?.detail == "4417" && door?.line == 17 && door?.raw == "- Door code B-Bau — 4417"
                  && door?.file == "Areas/Pocket.md", "\(String(describing: door))")
            let star = board.pocketFacts.first { $0.label == "Ayşe's room" }
            check("facts: * bullet and non-ASCII kept verbatim", star?.raw == "* Ayşe's room — Haus 3, Raum 214"
                  && star?.detail == "Haus 3, Raum 214", "\(String(describing: star))")
            let bare = board.pocketFacts.first { $0.label == "Studierendenwerk hotline" }
            check("facts: no detail → empty", bare?.detail == "" && bare?.text == "Studierendenwerk hotline")
            let wifi = board.pocketFacts.first { $0.label == "Wi-Fi (eduroam)" }
            check("facts: split on the FIRST em dash", wifi?.detail == "alp@uni-kassel.de — pass in Keychain",
                  "\(String(describing: wifi))")

            let again = try JSONDecoder().decode(Dashboard.self, from: JSONEncoder().encode(board))
            check("round trip keeps facts (and cards)", again.pocketFacts == board.pocketFacts
                  && again.pocket == board.pocket && again.pocketFile == board.pocketFile)
            // The cache shape is the CI shape: pocket.facts.
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(board)) as? [String: Any]
            let pocket = json?["pocket"] as? [String: Any]
            check("encoded under pocket.facts", (pocket?["facts"] as? [Any])?.count == 5)
        } catch {
            check("facts fixture decodes", false, "\(error)")
        }

        // Tolerant decoding.
        do {
            let v5 = try decode(#"{"version":5,"pocket":{"file":"Areas/Pocket.md","items":[{"id":"a","date":"2026-10-15","title":"Good"}]}}"#)
            check("v5 payload without facts → []", v5.pocketFacts.isEmpty && v5.pocket.count == 1)
            let wrong = try decode(#"{"version":6,"pocket":{"file":"Areas/Pocket.md","items":[{"id":"a","date":"2026-10-15","title":"Good"}],"facts":"oops"}}"#)
            check("wrong-type facts doesn't drop items", wrong.pocketFacts.isEmpty && wrong.pocket.map(\.title) == ["Good"])
            let obj = try decode(#"{"version":6,"pocket":{"items":[{"id":"a","date":"2026-10-15","title":"Good"}],"facts":{"a":1}}}"#)
            check("object-typed facts doesn't drop items", obj.pocketFacts.isEmpty && obj.pocket.count == 1)
            let bad = try decode(#"{"version":6,"pocket":{"file":"Areas/Pocket.md","items":[],"facts":[{"id":"f1","text":"Door — 1","label":"Door","detail":"1","file":"Areas/Pocket.md","line":3,"raw":"- Door — 1"},{"label":"no id or text"},42]}}"#)
            check("one bad fact dropped, rest kept", bad.pocketFacts.map(\.id) == ["f1"], "\(bad.pocketFacts)")
            let thin = try decode(#"{"version":6,"pocket":{"items":[],"facts":[{"id":"f2","text":"PIN — 0815"}]}}"#)
            check("fact with only id+text derives label/detail/raw",
                  thin.pocketFacts.first?.label == "PIN" && thin.pocketFacts.first?.detail == "0815"
                  && thin.pocketFacts.first?.raw == "- PIN — 0815" && thin.pocketFacts.first?.line == 0,
                  "\(thin.pocketFacts)")
        } catch {
            check("tolerant facts decoding", false, "\(error)")
        }

        // FactEditor: new lines.
        check("newLine: label + detail", FactEditor.newLine(label: "Door code", detail: "4417") == "- Door code — 4417")
        check("newLine: no detail", FactEditor.newLine(label: "  Hotline ", detail: "  ") == "- Hotline")
        check("newLine: one line only", FactEditor.newLine(label: "A\nB", detail: "x\n\ty") == "- A B — x y")
        check("newLine: em dash in label can't be re-split",
              FactEditor.parse(FactEditor.newLine(label: "A — B", detail: "c"))?.label == "A – B")
        let typed = FactEditor.split("Door code — 4417")
        check("split: typed text", typed.label == "Door code" && typed.detail == "4417")

        // FactEditor: parse / replaced.
        check("parse: bullet", FactEditor.parse("- Door code — 4417")?.detail == "4417")
        check("parse: indented star bullet", FactEditor.parse("  * Door code")?.label == "Door code")
        check("parse: not a bullet → nil", FactEditor.parse("## Cards") == nil && FactEditor.parse("plain") == nil)
        check("replaced: keeps '- '", FactEditor.replaced(line: "- Door code — 4417", label: "Door code", detail: "5521")
              == "- Door code — 5521")
        check("replaced: keeps indent and marker",
              FactEditor.replaced(line: "  * Old — x", label: "New", detail: "") == "  * New")
        check("replaced: non-bullet gets a fresh bullet",
              FactEditor.replaced(line: "garbage", label: "New", detail: "y") == "- New — y")

        // Locating a moved line, then editing / removing it.
        let note = ["# Pocket", "", "## Important", "", "- Inserted above", "- Door code B-Bau — 4417", "- Mensa PIN — 0815", "", "## Cards"]
        let staleHint = 4   // where the line used to be (1-based)
        let at = TaskLineEditor.locate("- Door code B-Bau — 4417", in: note, hint: staleHint)
        check("locate: moved line found by text", at == 5, "\(String(describing: at))")
        check("locate: plain bullet never matched as a checkbox",
              TaskLineEditor.locate("- [ ] Door code B-Bau — 4417", in: note, hint: 1) == nil)
        check("locate: edited-elsewhere line → nil", TaskLineEditor.locate("- Door code — 0000", in: note, hint: 6) == nil)
        let content = note.joined(separator: "\n") + "\n"
        let gone = FactEditor.removing("- Door code B-Bau — 4417", hint: staleHint, from: content)
        check("removing: only that line goes", gone == note.enumerated().filter { $0.offset != 5 }.map(\.element).joined(separator: "\n") + "\n",
              "\(String(describing: gone))")
        check("removing: line gone → nil", FactEditor.removing("- Nope", hint: 1, from: content) == nil)
        let crlf = "## Important\r\n- A — 1\r\n- B — 2\r\n"
        check("removing: CRLF file", FactEditor.removing("- A — 1", hint: 2, from: crlf) == "## Important\r\n- B — 2\r\n")

        // Inserting under `## Important`, never a To-Do-shaped file.
        let added = FactEditor.insert("- New — 1", in: content)
        check("insert: joins the Important list, before the blank line",
              added.components(separatedBy: "\n") == ["# Pocket", "", "## Important", "", "- Inserted above",
                                                      "- Door code B-Bau — 4417", "- Mensa PIN — 0815", "- New — 1", "", "## Cards", ""],
              added)
        let noSection = "# Pocket\n\n## Cards\n\n### 2026-10-15 · X\n\n## Calendar\n"
        let created = FactEditor.insert("- New — 1", in: noSection)
        check("insert: missing heading is created above ## Cards",
              created == "# Pocket\n\n## Important\n- New — 1\n\n## Cards\n\n### 2026-10-15 · X\n\n## Calendar\n", created)
        let skeleton = FactEditor.insert("- New — 1", in: FactEditor.template)
        check("skeleton: Pocket-shaped, nothing To-Do about it",
              skeleton.contains("# Pocket") && skeleton.contains("## Important\n- New — 1")
              && !skeleton.contains("Routines") && !skeleton.contains("# To Do") && !skeleton.contains("## To do"), skeleton)
        // What the vault parser would make of the inserted line (the contract's other half).
        check("insert → parse round trip", FactEditor.parse("- New — 1")?.label == "New")
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

        importantFacts(here)

        print("\n\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
