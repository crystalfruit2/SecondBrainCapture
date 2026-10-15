import Foundation

/// Pure string surgery for `Areas/To-Do.md` — the same "reason about it without
/// a token" contract as `TaskLineEditor`. Two things the task path never
/// needed: a routine's done-state lives in a `✅ YYYY-MM-DD` stamp rather than
/// the checkbox, and new items are inserted *under a heading*, not appended to
/// the end of the file (the note has three fixed sections).
enum TodoLineEditor {
    static let stampPattern = #"\s*✅\s*\d{4}-\d{2}-\d{2}"#

    /// Set a routine's done stamp to `date`, or remove it when nil.
    static func setDoneStamp(_ line: String, date: Date?) -> String {
        var s = line
        if let range = s.range(of: stampPattern, options: .regularExpression) {
            s.removeSubrange(range)
        }
        s = s.trimmingTrailingWhitespace()
        guard let date else { return s }
        return s + " ✅ " + DateFormatter.vaultDay.string(from: date)
    }

    /// Compose the vault line for a brand-new item.
    static func newLine(text: String, due: Date?, time: (hour: Int, minute: Int)?, recur: TodoRecur?) -> String {
        var s = "- [ ] "
        if let recur { s += "🔁 \(recur.rawValue) " }
        s += text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let due { s += " 📅 " + DateFormatter.vaultDay.string(from: due) }
        if due != nil, let time { s += String(format: " ⏰ %02d:%02d", time.hour, time.minute) }
        return s
    }
}

enum TodoFileEditor {
    /// The note skeleton written when the vault has no To-Do file yet (404).
    static let template = """
    ---
    tags:
      - area
      - personal
    status: active
    ---

    # To Do

    Personal to-do list, synced live with the **To Do** tab of Rocky's Vault.

    ## Routines

    ## To do

    ## Errands
    """

    /// Insert `line` as the last item of the section headed `heading`,
    /// creating the heading at the end of the file when it's missing. The
    /// insertion point is right after the section's last non-blank line, so
    /// the blank line that separates sections in the note stays where it is.
    ///
    /// `anchor`: when the heading is missing and the note has this heading,
    /// the new section is created just above it instead of at the end of the
    /// file (Pocket's `## Important` belongs before `## Cards`).
    static func insert(_ line: String, under heading: String, in content: String,
                       before anchor: String? = nil) -> String {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        let wanted = normalizeHeading(heading)

        guard let headingIndex = lines.firstIndex(where: { normalizeHeading($0) == wanted }) else {
            if let anchor, let at = lines.firstIndex(where: { normalizeHeading($0) == normalizeHeading(anchor) }) {
                lines.insert(contentsOf: [heading, line, ""], at: at)
                return lines.joined(separator: "\n")
            }
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append(contentsOf: [heading, line])
            return lines.joined(separator: "\n")
        }

        // Walk to the end of this section: the next `##`/`#` heading or EOF.
        var end = headingIndex + 1
        while end < lines.count, !isHeading(lines[end]) { end += 1 }
        // Back up over trailing blank lines so the item joins the list.
        var insertAt = end
        while insertAt > headingIndex + 1,
              lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        lines.insert(line, at: insertAt)
        return lines.joined(separator: "\n")
    }

    private static func isHeading(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("## ") || t.hasPrefix("# ")
    }

    private static func normalizeHeading(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Pure string surgery for the `## Important` bullets of `Areas/Pocket.md` —
/// plain `- label — detail` lines, **not** checkboxes, so none of the
/// checkbox helpers (`setDone`, `setDue`) apply. No UIKit/SwiftUI, so it runs
/// in `Checks/pocket_checks.swift` without Xcode.
enum FactEditor {
    static let heading = "## Important"
    /// A new `## Important` section goes above the cards, not after the calendar block.
    static let cardsAnchor = "## Cards"
    static let separator = PocketFact.separator

    /// Written when the vault has no Pocket note yet (404): just enough for
    /// Rocky and `build_dashboard.py` to carry on from. Deliberately not the
    /// To-Do template.
    static let template = """
    ---
    tags:
      - area
      - personal
    status: active
    ---

    # Pocket

    ## Important

    ## Cards
    """

    // Text rules live on `PocketFact` so DashboardModels.swift stands alone.
    static func clean(_ s: String) -> String { PocketFact.clean(s) }
    static func cleanLabel(_ s: String) -> String { PocketFact.cleanLabel(s) }

    /// `"Door code — 4417"` → ("Door code", "4417"); no separator → detail "".
    static func split(_ text: String) -> (label: String, detail: String) { PocketFact.split(text) }

    /// The vault line for a brand-new fact.
    static func newLine(label: String, detail: String) -> String { PocketFact.newLine(label: label, detail: detail) }

    /// Label and detail of a bullet line; nil when the line isn't a bullet.
    static func parse(_ line: String) -> (label: String, detail: String)? {
        guard let r = line.range(of: #"^\s*[-*+]\s+(?=\S)"#, options: .regularExpression) else { return nil }
        return split(String(line[r.upperBound...]))
    }

    /// `line` with its text replaced, keeping its indentation and bullet marker.
    /// A line that isn't a bullet at all is replaced by a fresh `- ` line.
    static func replaced(line: String, label: String, detail: String) -> String {
        let fresh = newLine(label: label, detail: detail)
        guard let r = line.range(of: #"^\s*[-*+]\s+(?=\S)"#, options: .regularExpression) else { return fresh }
        return String(line[..<r.upperBound]) + String(fresh.dropFirst(2))
    }

    /// Insert a new bullet under `## Important` (created above `## Cards` when absent).
    static func insert(_ line: String, in content: String) -> String {
        TodoFileEditor.insert(line, under: heading, in: content, before: cardsAnchor)
    }

    /// `content` without the bullet matching `expected` (located like every
    /// other single-line edit: exact text beats the stale line-number hint).
    /// Nil when the line is gone.
    static func removing(_ expected: String, hint: Int, from content: String) -> String? {
        var lines = content.components(separatedBy: "\n")
        guard let index = TaskLineEditor.locate(expected, in: lines, hint: hint) else { return nil }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
