import Foundation

/// Pure parsers for the markdown blocks `/finance` writes into `Areas/Finance.md`
/// (mirrored into `dashboard.json.finance.blocks`). No SwiftUI import on purpose —
/// a throwaway `swift` script can concatenate this file and assert on it.

struct FinanceRule: Identifiable, Equatable {
    enum Status: Equatable { case fired, info, ok, unknown }
    let id: String
    let status: Status
    let measure: String
    let task: String
    var isFired: Bool { status == .fired }
}

struct FinanceCalendarEntry: Identifiable, Equatable {
    let date: String      // dd.MM.yyyy as written by the vault
    let daysAway: Int?
    let what: String
    var id: String { "\(date)|\(what)" }
}

struct FinanceBriefSection: Identifiable, Equatable {
    let title: String
    let body: String
    var id: String { title }
}

enum FinanceParser {
    /// Rules block table: `| \`id\` | 🔴 tetik / ✅ / ℹ️ | measure | evet/— |`.
    /// Header ("Kural"), separator and any non-table preamble are skipped; rows with
    /// fewer than 4 cells (a vault-side truncation) are dropped. Fired rows come first,
    /// otherwise the vault's order is kept.
    static func rules(from markdown: String) -> [FinanceRule] {
        var out: [FinanceRule] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { continue }
            let cells = splitTableRow(line)
            guard cells.count >= 4 else { continue }
            let id = cells[0].replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
            if id.isEmpty || id == "Kural" || id.allSatisfy({ $0 == "-" || $0 == ":" }) { continue }
            // Compare the first unicode scalar, not the grapheme: "ℹ️" is ℹ + U+FE0F,
            // so `hasPrefix("ℹ")` is false while the scalar test is stable.
            let first = cells[1].unicodeScalars.first
            let status: FinanceRule.Status
            if first == "🔴" { status = .fired }
            else if first == "ℹ" { status = .info }
            else if first == "✅" { status = .ok }
            else { status = .unknown }
            out.append(FinanceRule(id: id, status: status, measure: cells[2], task: cells[3]))
        }
        let fired = out.filter { $0.isFired }
        return fired + out.filter { !$0.isFired }
    }

    /// Calendar block lines: `- dd.MM.yyyy (+N gün): what`.
    static func calendar(from markdown: String) -> [FinanceCalendarEntry] {
        let pattern = #"^-\s+(\d{2}\.\d{2}\.\d{4})\s+\(([+-]?\d+)\s+gün\):\s*(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [FinanceCalendarEntry] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges == 4,
                  let r1 = Range(m.range(at: 1), in: line), let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else { continue }
            out.append(FinanceCalendarEntry(date: String(line[r1]), daysAway: Int(line[r2]), what: String(line[r3])))
        }
        return out
    }

    /// The Sunday brief is a numbered list of bold-led paragraphs ("**1. Toplam …:** …")
    /// with markdown tables in between. Split at each "**N." line; the first H2 line and
    /// the trailing italic disclaimer are dropped; table lines stay inside the body.
    static func briefSections(from markdown: String) -> [FinanceBriefSection] {
        var sections: [FinanceBriefSection] = []
        var title = ""
        var body: [String] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty || !text.isEmpty { sections.append(FinanceBriefSection(title: title, body: text)) }
            body = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") { continue }
            if t.hasPrefix("_") && t.hasSuffix("_") && t.count > 2 { continue }     // disclaimer / preamble lines
            if let m = t.range(of: #"^\*\*\d+\.\s"#, options: .regularExpression) {
                flush()
                // "**1. Toplam (0320 + 0342):** rest" → title "1. Toplam (0320 + 0342)", body "rest"
                let afterStars = t[m.upperBound...]
                if let close = afterStars.range(of: ":**") ?? afterStars.range(of: "**") {
                    title = String(t[t.index(t.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let rest = String(afterStars[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { body.append(rest) }
                } else {
                    title = t.replacingOccurrences(of: "**", with: "")
                }
                continue
            }
            body.append(line)
        }
        flush()
        return sections
    }

    /// Split a markdown table row into trimmed cells.
    static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A markdown table (lines starting with "|") → header + rows, separator dropped.
    static func table(from lines: [String]) -> (header: [String], rows: [[String]]) {
        var header: [String] = []
        var rows: [[String]] = []
        for line in lines where line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let cells = splitTableRow(line)
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty }) { continue }
            if header.isEmpty { header = cells } else { rows.append(cells) }
        }
        return (header, rows)
    }
}
