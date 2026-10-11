import Foundation

/// One expense as the phone knows it. `rawAmount` is the text Shortcuts handed
/// over ("4,50 €", whitespace tidied); `amount` is the parsed decimal as a
/// plain dot-decimal string, or nil when the text couldn't be read — the vault
/// then flags the row instead of guessing.
///
/// `stamp` and `filename` are fixed when the entry is created, not when it is
/// uploaded: a tap made offline and synced after landing in another time zone
/// must keep the wall-clock time of the payment, and a retry must hit the
/// same path as the first attempt.
struct ExpenseEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let stamp: String
    let filename: String
    let rawAmount: String
    let amount: String?
    let currency: String?
    let merchant: String
    let card: String
    let note: String
    let source: String
    var synced: Bool

    init(rawAmount: String, merchant: String, card: String, note: String = "",
         source: String = "apple-pay", createdAt: Date = Date(), id: UUID = UUID(),
         timeZone: TimeZone = .current) {
        let parsed = ExpenseParser.parseAmount(rawAmount)
        self.id = id
        self.createdAt = createdAt
        self.stamp = ExpenseParser.timestamp(createdAt, timeZone: timeZone)
        self.filename = ExpenseParser.dropFilename(id: id, date: createdAt, timeZone: timeZone)
        self.rawAmount = rawAmount
        self.amount = parsed.value.map(ExpenseParser.decimalString)
        self.currency = parsed.currency
        self.merchant = merchant
        self.card = card
        self.note = note
        self.source = source
        self.synced = false
    }

    /// Only `id` and `createdAt` are required when reading back from disk, so
    /// a file written by an older or newer build still loads — an entry that
    /// fails to decode would take every unsynced expense in the file with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        stamp = try c.decodeIfPresent(String.self, forKey: .stamp) ?? ExpenseParser.timestamp(createdAt)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
            ?? ExpenseParser.dropFilename(id: id, date: createdAt)
        rawAmount = try c.decodeIfPresent(String.self, forKey: .rawAmount) ?? ""
        amount = try c.decodeIfPresent(String.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant) ?? ""
        card = try c.decodeIfPresent(String.self, forKey: .card) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "apple-pay"
        synced = try c.decodeIfPresent(Bool.self, forKey: .synced) ?? false
    }

    /// "REWE · 4,50 €" — the raw text is what the user saw on the terminal,
    /// so it's shown as is rather than re-formatted.
    var summaryLine: String {
        let place = merchant.isEmpty ? "Unknown place" : merchant
        return rawAmount.isEmpty ? place : "\(place) · \(rawAmount)"
    }
}

/// Pure helpers for the expense log — no UIKit, no network, so the checks in
/// `Checks/expense_checks.swift` can exercise them from the command line.
enum ExpenseParser {
    /// Vault folder the phone drops expenses into, one new file per expense.
    /// `finance.py expenses fold` moves them into the monthly ledger.
    static let inboxFolder = "Areas/Finance/expenses/inbox"

    /// What is left of the text once the number is taken out must be exactly
    /// one of these to count as a known currency. Anything else ("zł", "CA$",
    /// "kr") is kept as written, so the vault leaves the row out of the
    /// main-currency total instead of booking it as euros.
    private static let currencyTokens: [String: String] = [
        "€": "EUR", "EUR": "EUR", "$": "USD", "USD": "USD", "US$": "USD", "£": "GBP", "GBP": "GBP",
        "₺": "TRY", "TRY": "TRY", "TL": "TRY", "CHF": "CHF",
    ]

    /// Lenient currency-text parser; mirrors `parse_amount` in the vault's
    /// `fin/expenses.py` (same table of cases on both sides).
    ///
    /// "4,50 €" → 4.50 EUR · "€1.234,56" → 1234.56 EUR · "1,234.56" → 1234.56
    /// ".50 €" → 0.50 EUR · "5,- €" → 5 EUR · "7,00 zł" → 7.00 "ZŁ"
    /// "2x 3,50 €" → nil: two numbers, so no guess.
    /// One separator followed by exactly three digits is a thousands mark
    /// ("1.234" → 1234): a currency amount never carries three decimals.
    static func parseAmount(_ text: String) -> (value: Decimal?, currency: String?) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return (nil, nil) }
        let chars = Array(s)
        guard let start = chars.firstIndex(where: isDigit) else { return (nil, currency(of: s, strict: true)) }
        var end = start
        while end < chars.count, isNumberRun(chars[end]) { end += 1 }
        let prefix = chars[..<start]
        let suffix = chars[end...]
        if suffix.contains(where: isDigit) { return (nil, nil) }

        let compact = chars[start..<end].filter { !$0.isWhitespace && $0 != "'" && $0 != "’" }
        let endedWithSeparator = compact.last == "." || compact.last == ","   // "5,-" is five flat, not minus five
        var num = String(compact)
        while let last = num.last, last == "." || last == "," { num.removeLast() }

        let firstAfter = suffix.first(where: { !$0.isWhitespace })
        let negative = prefix.contains(where: { "-−–".contains($0) })
            || (prefix.contains("(") && suffix.contains(")"))
            || (!endedWithSeparator && (firstAfter == "-" || firstAfter == "−"))
        let rest = String(prefix) + String(suffix)

        if let before = prefix.last, before == "." || before == "," {
            num = num.allSatisfy(isDigit) ? "0." + num : "x"      // ".50": the run is the fraction
        } else {
            let dots = num.filter { $0 == "." }.count
            let commas = num.filter { $0 == "," }.count
            if dots > 0 && commas > 0 {
                let decimalSep: Character = num.lastIndex(of: ".")! > num.lastIndex(of: ",")! ? "." : ","
                let thousandsSep: Character = decimalSep == "." ? "," : "."
                num = String(num.filter { $0 != thousandsSep }).replacingOccurrences(of: String(decimalSep), with: ".")
            } else if dots > 0 || commas > 0 {
                let sep: Character = dots > 0 ? "." : ","
                let cut = num.lastIndex(of: sep)!
                let head = String(num[..<cut])
                let tail = String(num[num.index(after: cut)...])
                if max(dots, commas) > 1 || (tail.count == 3 && (1...3).contains(head.count) && head != "0") {
                    num = String(num.filter { $0 != sep })
                } else {
                    num = num.replacingOccurrences(of: String(sep), with: ".")
                }
            }
        }
        // `Decimal(string:)` accepts a numeric prefix and ignores the rest, so
        // insist on the exact shape first ("1.2.3" must not read as 1.2).
        guard isPlainDecimal(num), let value = Decimal(string: num, locale: Locale(identifier: "en_US_POSIX")) else {
            return (nil, currency(of: rest, strict: true))
        }
        return (negative ? -value : value, currency(of: rest, strict: false))
    }

    /// `strict`: only a known currency counts (used when there is no readable
    /// number to attach an unknown one to).
    private static func currency(of rest: String, strict: Bool) -> String? {
        let residue = String(rest.filter { !$0.isWhitespace && !"-−–+().,'’".contains($0) }).uppercased()
        guard !residue.isEmpty else { return nil }
        if let code = currencyTokens[residue] { return code }
        return strict ? nil : String(residue.prefix(8))
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func isNumberRun(_ c: Character) -> Bool {
        isDigit(c) || c == "." || c == "," || c == "'" || c == "’" || c.isWhitespace
    }

    private static func isPlainDecimal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(isDigit) }
    }

    /// Plain dot-decimal text ("4.5", "-1234.56") — locale-free, for the vault.
    static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// The phone's own wall clock with an explicit UTC offset
    /// ("2026-10-06T09:30:15+02:00", and "+00:00" rather than "Z" in London):
    /// the vault files the expense under the date where it was paid, and only
    /// re-zones a stamp that carries no wall clock at all.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// `20261006-093015-a1b2c3d4.json` — time for a readable listing, the id's
    /// first block so two taps in one second can't collide.
    static func dropFilename(id: UUID, date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        return "\(f.string(from: date))-\(id.uuidString.prefix(8).lowercased()).json"
    }

    /// The JSON the vault's `row_from_drop` reads. `amount` and `currency` are
    /// null (not omitted) when unknown so the contract has one shape.
    static func dropJSON(for entry: ExpenseEntry) -> Data {
        let body: [String: Any] = [
            "v": 1,
            "id": entry.id.uuidString,
            "ts": entry.stamp,
            "amount": entry.amount ?? NSNull(),
            "currency": entry.currency ?? NSNull(),
            "merchant": entry.merchant,
            "card": entry.card,
            "raw_amount": entry.rawAmount,
            "note": entry.note,
            "source": entry.source,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}
