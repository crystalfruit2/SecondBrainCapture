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
    static func insert(_ line: String, under heading: String, in content: String) -> String {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        let wanted = normalizeHeading(heading)

        guard let headingIndex = lines.firstIndex(where: { normalizeHeading($0) == wanted }) else {
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

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
