// Checks for the expense log: the amount parser, the drop-file format, the
// upload queue, and both contracts with the vault. No Xcode project, simulator
// or network needed — run from the repo root:
//
//   S=SecondBrainCapture
//   swiftc -parse-as-library $S/ExpenseParser.swift $S/ExpenseStore.swift $S/GitHubService.swift \
//          $S/AppConfig.swift $S/KeychainStore.swift $S/DashboardModels.swift \
//          Checks/expense_checks.swift -o /tmp/expense_checks
//   /tmp/expense_checks [output-dir]
//
// Contracts with the vault (`second_brain/.claude/skills/finance`):
// - phone → vault: with an output directory this writes drop files exactly as
//   the app uploads them. The vault keeps a copy in `tests/ios-drops/` and
//   folds them in `tests/test_expenses.py`; after changing the drop format,
//   regenerate and copy them over.
// - vault → phone: `Checks/fixtures/spending-payload.json` is real output of
//   the vault's `dashboard_payload` (run on these drops plus four typed
//   entries, with a made-up config); it is decoded here with the app's models.

import Foundation

@main
enum ExpenseChecks {
    static var failures = 0
    static var passed = 0

    static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failures += 1; print("FAIL: \(what())") }
    }

    static let posix = Locale(identifier: "en_US_POSIX")
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    // Same table as AMOUNT_CASES in the vault's tests/test_expenses.py — keep the two identical.
    static let amountCases: [(String, String?, String?)] = [
        ("4,50 €", "4.50", "EUR"), ("€4.50", "4.50", "EUR"), ("EUR 1.234,56", "1234.56", "EUR"), ("1,234.56", "1234.56", nil),
        ("12", "12", nil), ("4,5", "4.5", nil), ("1.234", "1234", nil), ("0.500", "0.500", nil), ("1.234.567", "1234567", nil),
        ("1 234,56 €", "1234.56", "EUR"), ("1'234.50 CHF", "1234.50", "CHF"), ("-3,20 €", "-3.20", "EUR"), ("− 3,20", "-3.20", nil),
        ("(3,20)", "-3.20", nil), ("3,20-", "-3.20", nil), ("$7.00", "7.00", "USD"), ("149,99 TL", "149.99", "TRY"),
        ("₺1.250,00", "1250.00", "TRY"), ("4.50", "4.50", nil), ("1234.5", "1234.5", nil), ("12,345", "12345", nil),
        ("0,99", "0.99", nil), ("", nil, nil), ("abc", nil, nil), ("€", nil, "EUR"),
        // an unknown currency is kept as written, never booked as the main one
        ("7,00 zł", "7.00", "ZŁ"), ("¥500", "500", "¥"), ("CA$7.00", "7.00", "CA$"), ("100 kr", "100", "KR"), ("US$4.50", "4.50", "USD"),
        ("4,50 € x", "4.50", "€X"),
        // shapes a naive reader gets wrong
        (".50 €", "0.50", "EUR"), ("5,- €", "5", "EUR"), ("5,– €", "5", "EUR"), ("2x 3,50 €", nil, nil), ("1,2.3,4", nil, nil),
        ("1234.567", "1234.567", nil), ("–3,20", "-3.20", nil), ("1’234.50", "1234.50", nil),
    ]

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    static func entry(_ raw: String, _ merchant: String, _ id: String, at when: Date, card: String = "Debit Card") -> ExpenseEntry {
        ExpenseEntry(rawAmount: raw, merchant: merchant, card: card, createdAt: when, id: UUID(uuidString: id)!, timeZone: berlin)
    }

    static func json(_ e: ExpenseEntry) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: ExpenseParser.dropJSON(for: e)) as? [String: Any]) ?? [:]
    }

    static func main() async {
        parserChecks()
        let samples = entryChecks()
        githubChecks()
        payloadChecks()
        await storeChecks()

        if CommandLine.arguments.count > 1 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for e in samples {
                try? ExpenseParser.dropJSON(for: e).write(to: dir.appendingPathComponent(e.filename))
            }
            print("wrote \(samples.count) drop files to \(dir.path)")
        }
        print("\(passed) checks passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - parser

    static func parserChecks() {
        for (text, want, currency) in amountCases {
            let got = ExpenseParser.parseAmount(text)
            let expected = want.flatMap { Decimal(string: $0, locale: posix) }
            check(got.value == expected, "parseAmount(\(text.debugDescription)) = \(String(describing: got.value)), want \(String(describing: want))")
            check(got.currency == currency, "parseAmount(\(text.debugDescription)) currency = \(String(describing: got.currency)), want \(String(describing: currency))")
        }
        // Spaces Shortcuts can hand over in a formatted amount: NBSP and narrow NBSP.
        check(ExpenseParser.parseAmount("1\u{202F}234,56\u{00A0}€").value == Decimal(string: "1234.56", locale: posix), "narrow-space thousands")
        check(ExpenseParser.decimalString(Decimal(string: "-1234.56", locale: posix)!) == "-1234.56", "decimalString")
    }

    // MARK: - entry → drop file

    static func entryChecks() -> [ExpenseEntry] {
        let when = date(2026, 10, 6, 7, 30, 15)     // 09:30:15 in Berlin
        let rewe = entry("4,50 €", "REWE Markt GmbH", "A1B2C3D4-0000-4000-8000-000000000001", at: when)
        check(rewe.amount == "4.5" && rewe.currency == "EUR", "entry parses its raw amount: \(String(describing: rewe.amount))")
        check(!rewe.synced, "a new entry starts unsynced")
        check(rewe.summaryLine == "REWE Markt GmbH · 4,50 €", "summaryLine: \(rewe.summaryLine)")
        check(rewe.stamp == "2026-10-06T09:30:15+02:00", "stamp: \(rewe.stamp)")
        check(rewe.filename == "20261006-093015-a1b2c3d4.json", "filename: \(rewe.filename)")
        // London in winter: an explicit +00:00, never "Z" (the vault re-zones a bare Z).
        let london = ExpenseEntry(rawAmount: "£3.00", merchant: "Pret", card: "Debit Card", createdAt: date(2026, 12, 1, 12, 0, 0),
                                  timeZone: TimeZone(identifier: "Europe/London")!)
        check(london.stamp == "2026-12-01T12:00:00+00:00", "UTC+0 stamp: \(london.stamp)")

        // Stamp and path are fixed at creation: syncing later from another zone changes neither.
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
        check(json(rewe)["ts"] as? String == "2026-10-06T09:30:15+02:00", "ts survives a zone change before upload")
        if let data = try? JSONEncoder().encode(rewe), let back = try? JSONDecoder().decode(ExpenseEntry.self, from: data) {
            check(back.filename == rewe.filename && back.stamp == rewe.stamp, "a reloaded entry targets the same path")
        } else {
            check(false, "entry round trip under another zone")
        }
        NSTimeZone.default = previousZone

        let body = json(rewe)
        check(body["id"] as? String == rewe.id.uuidString, "json id")
        check(body["amount"] as? String == "4.5", "json amount is a decimal string")
        check(body["raw_amount"] as? String == "4,50 €", "json keeps the raw text")
        check(body["merchant"] as? String == "REWE Markt GmbH" && body["card"] as? String == "Debit Card", "json merchant/card")
        check(body["source"] as? String == "apple-pay" && body["v"] as? Int == 1, "json source/v")

        // Wallet delivered nothing: still an entry, amount null (not omitted), raw text empty.
        let blank = entry("", "", "B2C3D4E5-0000-4000-8000-000000000002", at: when, card: "")
        let blankBody = json(blank)
        check(blank.amount == nil && blank.summaryLine == "Unknown place", "blank entry")
        check(blankBody["amount"] is NSNull && blankBody["currency"] is NSNull, "unreadable amount is JSON null")
        check(blankBody.keys.sorted() == body.keys.sorted(), "same JSON shape with or without an amount")

        // An amount the phone can't read keeps its raw text for the vault to try (or flag).
        let odd = entry("vier fünfzig", "Stadtbäckerei Schmidt", "C3D4E5F6-0000-4000-8000-000000000003", at: when.addingTimeInterval(3600))
        check(odd.amount == nil && json(odd)["raw_amount"] as? String == "vier fünfzig", "unparsed amount keeps raw text")

        let dollars = entry("$12.00", "Online Shop Inc", "D4E5F607-0000-4000-8000-000000000004", at: when.addingTimeInterval(7200))
        let zloty = entry("7,00 zł", "Zabka", "E5F60718-0000-4000-8000-000000000005", at: when.addingTimeInterval(10800))
        check(zloty.currency == "ZŁ" && json(zloty)["currency"] as? String == "ZŁ", "unknown currency travels as written")

        // Entries survive their own persistence format (what ExpenseStore writes to disk).
        if let data = try? JSONEncoder().encode([rewe, blank, odd]),
           let back = try? JSONDecoder().decode([ExpenseEntry].self, from: data) {
            check(back == [rewe, blank, odd], "Codable round trip")
        } else {
            check(false, "Codable round trip threw")
        }
        // A file from a build that knew fewer (or more) fields must still load,
        // and an entry with no `synced` flag counts as not yet uploaded.
        let sparse = Data(#"[{"id":"A1B2C3D4-0000-4000-8000-000000000001","createdAt":0,"futureField":true}]"#.utf8)
        if let old = try? JSONDecoder().decode([ExpenseEntry].self, from: sparse), let first = old.first {
            check(first.rawAmount == "" && first.amount == nil && first.source == "apple-pay" && !first.synced, "sparse entry defaults")
            check(first.filename.hasSuffix("-a1b2c3d4.json") && !first.stamp.isEmpty, "sparse entry derives its path")
        } else {
            check(false, "sparse / forward-compatible entry failed to decode")
        }
        return [rewe, blank, odd, dollars, zloty]
    }

    // MARK: - GitHub's answer to a repeated create

    static func githubChecks() {
        // Measured against the API on 2026-10-06 (create without sha on an existing path, HTTP 422).
        let measured = "Invalid request.\n\n\"sha\" wasn't supplied."
        check(GitHubService.meansAlreadyThere(measured, pathIsUnique: true), "measured 422 counts as landed for a unique path")
        check(!GitHubService.meansAlreadyThere(measured, pathIsUnique: false), "…but not for a shared path (the caller must retry and append)")
        check(GitHubService.meansAlreadyThere("File already exists", pathIsUnique: false), "legacy wording")
        check(!GitHubService.meansAlreadyThere("Validation Failed", pathIsUnique: true), "any other 422 stays an error")
    }

    // MARK: - vault → phone

    static func payloadChecks() {
        // `#filePath` is whatever path the compiler was given, so a relative
        // one only resolves when run from the repo root — as the header says.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/spending-payload.json")
        guard let data = try? Data(contentsOf: url) else { check(false, "missing fixture \(url.path) — run from the repo root"); return }
        guard let p = try? JSONDecoder().decode(SpendingPayload.self, from: data) else { check(false, "SpendingPayload failed to decode"); return }
        // Every model field has a fallback, so a renamed key would decode "fine"
        // and render blank — assert real values from the vault's output instead.
        check(p.month == "2026-10" && p.label == "Ekim 2026" && p.symbol == "€", "payload month/label/symbol: \(p.month) \(p.label) \(p.symbol)")
        check(p.total == "98,00" && p.count == 9 && p.countLine == "9 işlem", "payload total/count: \(p.total) \(p.count) \(p.countLine)")
        check(p.budgetLine == "aylık ödeme €1.000,00 → kalan €902,00", "payload budgetLine: \(String(describing: p.budgetLine))")
        check(p.byCategory.first?.name == "ulaşım" && p.byCategory.first?.total == "49,00" && p.byCategory.first?.count == 1,
              "payload byCategory: \(String(describing: p.byCategory.first))")
        check(p.byCategory.contains { $0.name == "kategorisiz" }, "uncategorised rows are named")
        check(p.recent.count == 9, "payload recent rows: \(p.recent.count)")
        if let zabka = p.recent.first(where: { $0.merchant == "Zabka" }) {
            check(zabka.amount == "7,00 ZŁ" && zabka.shortDate == "06.10" && zabka.time == "12:30", "foreign row: \(zabka.amount) \(zabka.shortDate) \(zabka.time)")
        } else {
            check(false, "payload has no Zabka row")
        }
        if let rewe = p.recent.first(where: { $0.merchant == "REWE Markt GmbH" }) {
            check(rewe.amount == "4,50" && rewe.category == "market" && rewe.id == "A1B2C3D4-0000-4000-8000-000000000001", "REWE row: \(rewe)")
        } else {
            check(false, "payload has no REWE row")
        }
        check(p.warnings.count == 3 && p.warnings[0].contains("tutar okunamadı"), "payload warnings: \(p.warnings)")
        check(p.note?.contains("SEPA") == true, "payload note")
    }

    // MARK: - the upload queue

    final class Recorder {
        var calls: [UUID] = []
    }

    @MainActor
    static func storeChecks() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("expense-checks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var counter = 0
        func freshStore() -> (ExpenseStore, URL) {
            counter += 1
            let url = dir.appendingPathComponent("expenses-\(counter).json")
            return (ExpenseStore(fileURL: url, watchNetwork: false), url)
        }
        let offline = URLError(.notConnectedToInternet)

        // 1. Oldest first, both land, nothing left waiting.
        do {
            let (store, url) = freshStore()
            let rec = Recorder()
            let a = store.record(rawAmount: "1,00 €", merchant: "A", card: "c", createdAt: Date(timeIntervalSince1970: 100))
            let b = store.record(rawAmount: "2,00 €", merchant: "B", card: "c", createdAt: Date(timeIntervalSince1970: 200))
            store.upload = { e, _ in rec.calls.append(e.id) }
            let done = await store.flush()
            check(done && rec.calls == [a.id, b.id] && store.pendingCount == 0 && store.lastError == nil, "flush uploads oldest first")
            let reloaded = ExpenseStore(fileURL: url, watchNetwork: false)
            check(reloaded.entries.count == 2 && reloaded.pendingCount == 0, "synced state is persisted")
        }
        // 2. Offline: stop at the first failure, keep everything, say why; a later flush sends it all.
        do {
            let (store, url) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.record(rawAmount: "2,00 €", merchant: "B", card: "c")
            store.upload = { e, _ in rec.calls.append(e.id); throw offline }
            let done = await store.flush()
            check(!done && rec.calls.count == 1 && store.pendingCount == 2 && store.lastError != nil, "offline stops the flush and keeps both")
            check(ExpenseStore(fileURL: url, watchNetwork: false).pendingCount == 2, "unsent entries survive a restart")
            store.upload = { e, _ in rec.calls.append(e.id) }
            let later = await store.flush()
            check(later && store.pendingCount == 0 && store.lastError == nil, "the next flush sends what was waiting")
        }
        // 3. One entry GitHub refuses must not hold the others back.
        do {
            let (store, _) = freshStore()
            let bad = store.record(rawAmount: "1,00 €", merchant: "Refused", card: "c", createdAt: Date(timeIntervalSince1970: 100))
            let good = store.record(rawAmount: "2,00 €", merchant: "Fine", card: "c", createdAt: Date(timeIntervalSince1970: 200))
            store.upload = { e, _ in if e.id == bad.id { throw GitHubError.badResponse(422, "Validation Failed") } }
            let done = await store.flush()
            check(!done && store.isSynced(good.id) && !store.isSynced(bad.id), "a refused entry is skipped, the rest go through")
            check(store.lastError?.contains("422") == true, "the refusal is reported: \(String(describing: store.lastError))")
        }
        // 4. 409 (branch moved mid-write) is retried at once.
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.upload = { e, _ in
                rec.calls.append(e.id)
                if rec.calls.count == 1 { throw GitHubError.badResponse(409, "is at abc but expected def") }
            }
            let done = await store.flush()
            check(done && rec.calls.count == 2, "409 is retried once and lands")
        }
        // 5. A bad token stops everything at the first call.
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.record(rawAmount: "2,00 €", merchant: "B", card: "c")
            store.upload = { e, _ in rec.calls.append(e.id); throw GitHubError.badResponse(401, "Bad credentials") }
            let done = await store.flush()
            check(!done && rec.calls.count == 1 && store.pendingCount == 2, "401 stops the flush")
            check(store.lastError?.contains("401") == true, "401 is reported: \(String(describing: store.lastError))")
        }
        // 6. Past the deadline nothing is attempted.
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.upload = { e, _ in rec.calls.append(e.id) }
            let done = await store.flush(deadline: Date().addingTimeInterval(-1))
            check(!done && rec.calls.isEmpty && store.pendingCount == 1, "deadline in the past: no upload")
        }
        // 7. A payment recorded while a flush is in the air goes out in that same flush.
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "First", card: "c", createdAt: Date(timeIntervalSince1970: 100))
            store.upload = { e, _ in
                rec.calls.append(e.id)
                if rec.calls.count == 1 { store.record(rawAmount: "2,00 €", merchant: "Second tap", card: "c") }
            }
            let done = await store.flush()
            check(done && rec.calls.count == 2 && store.entries.count == 2 && store.pendingCount == 0, "entry recorded mid-flush is uploaded too")
        }
        // 8. A second flush while one is running does not upload anything twice.
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.upload = { e, _ in
                rec.calls.append(e.id)
                _ = await store.flush()            // re-entrant call during the upload
            }
            let done = await store.flush()
            check(done && rec.calls.count == 1, "re-entrant flush is a no-op")
        }
        // 9. An unreadable queue file is set aside, never overwritten.
        do {
            let url = dir.appendingPathComponent("expenses-garbage.json")
            let garbage = Data("{ this is not the queue ".utf8)
            try? garbage.write(to: url)
            let store = ExpenseStore(fileURL: url, watchNetwork: false)
            store.record(rawAmount: "1,00 €", merchant: "After", card: "c")
            let kept = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first { $0.lastPathComponent.hasPrefix("expenses-unreadable-") }
            check(kept != nil && (try? Data(contentsOf: kept!)) == garbage, "unreadable queue file is preserved")
            check(store.entries.count == 1 && store.lastSaveSucceeded, "…and logging continues")
        }
        // 10. Trimming drops only old synced entries.
        do {
            let (store, _) = freshStore()
            store.upload = { _, _ in }
            for i in 0..<60 { store.record(rawAmount: "1,00 €", merchant: "S\(i)", card: "c", createdAt: Date(timeIntervalSince1970: Double(i))) }
            _ = await store.flush()
            store.upload = { _, _ in throw offline }
            store.record(rawAmount: "9,00 €", merchant: "Waiting 1", card: "c")
            store.record(rawAmount: "9,00 €", merchant: "Waiting 2", card: "c")
            _ = await store.flush()
            check(store.entries.count == 52 && store.pendingCount == 2, "trim keeps 50 synced + every unsynced: \(store.entries.count)/\(store.pendingCount)")
            check(store.oldestPending != nil, "oldestPending")
        }
        // 11. Shortcuts variables with newlines and runs of spaces are stored as one tidy line, capped.
        do {
            let (store, _) = freshStore()
            let e = store.record(rawAmount: " 4,50\u{00A0}€\n", merchant: "REWE\n  Markt", card: "c")
            check(e.rawAmount == "4,50 €" && e.merchant == "REWE Markt" && e.amount == "4.5", "tidy: \(e.rawAmount.debugDescription) \(e.merchant.debugDescription)")
            let long = store.record(rawAmount: "1 €", merchant: String(repeating: "x", count: 300), card: "c")
            check(long.merchant.count == 200, "merchant capped at 200: \(long.merchant.count)")
        }
        // 12. 403 stops the flush like 401 (a revoked token, not a per-entry refusal).
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.record(rawAmount: "2,00 €", merchant: "B", card: "c")
            store.upload = { e, _ in rec.calls.append(e.id); throw GitHubError.badResponse(403, "Resource not accessible") }
            let done = await store.flush()
            check(!done && rec.calls.count == 1 && store.lastError?.contains("403") == true, "403 stops the flush")
        }
        // 13. The request timeout reaches the uploader; oldestPending is the oldest.
        do {
            let (store, _) = freshStore()
            var seen: TimeInterval?? = nil
            let old = store.record(rawAmount: "1,00 €", merchant: "Old", card: "c", createdAt: Date(timeIntervalSince1970: 100))
            store.record(rawAmount: "2,00 €", merchant: "New", card: "c", createdAt: Date(timeIntervalSince1970: 200))
            check(store.oldestPending == old.createdAt, "oldestPending is the oldest unsynced")
            store.upload = { _, timeout in seen = .some(timeout) }
            _ = await store.flush(requestTimeout: 8)
            check(seen == .some(8), "request timeout is passed through: \(String(describing: seen))")
        }
        // 14. A second flush while one is running joins it: one upload, both callers get the result.
        do {
            let (store, _) = freshStore()
            let rec = Recorder()
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            store.upload = { e, _ in
                rec.calls.append(e.id)
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            async let first = store.flush()
            try? await Task.sleep(nanoseconds: 20_000_000)
            async let second = store.flush(deadline: Date().addingTimeInterval(10))
            let (a, b) = await (first, second)
            check(a && b && rec.calls.count == 1 && store.pendingCount == 0, "concurrent flush joins the running one: calls \(rec.calls.count)")
        }
        // 15. Cancelling the caller cancels the request; nothing is marked synced, no error is recorded.
        do {
            let (store, _) = freshStore()
            store.record(rawAmount: "1,00 €", merchant: "Slow", card: "c")
            store.upload = { _, _ in
                try await Task.sleep(nanoseconds: 3_000_000_000)   // throws CancellationError when cancelled
            }
            let started = Date()
            let flushing = Task { await store.flush() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            flushing.cancel()
            let result = await flushing.value
            let elapsed = Date().timeIntervalSince(started)
            check(!result && elapsed < 1 && store.pendingCount == 1 && store.lastError == nil && !store.isFlushing,
                  "cancelled flush ends early (\(Int(elapsed * 1000)) ms), keeps the entry, records no error")
            store.upload = { _, _ in }
            check(await store.flush(), "a flush after a cancelled one runs again")
        }
        // 16. The network monitor flushes on a return of connectivity, never on its first report.
        do {
            check(!ExpenseStore.networkCameBack(previous: nil, now: true), "first report (online) is not a transition")
            check(!ExpenseStore.networkCameBack(previous: nil, now: false), "first report (offline) is not a transition")
            check(!ExpenseStore.networkCameBack(previous: true, now: true), "still online is not a transition")
            check(ExpenseStore.networkCameBack(previous: false, now: true), "offline → online is")
            check(!ExpenseStore.networkCameBack(previous: true, now: false), "online → offline is not")
        }
        // 17. A queue file that cannot be written is reported, not pretended.
        do {
            let store = ExpenseStore(fileURL: dir.appendingPathComponent("missing-dir/expenses.json"), watchNetwork: false)
            store.record(rawAmount: "1,00 €", merchant: "A", card: "c")
            check(!store.lastSaveSucceeded && store.pendingCount == 1, "save failure is visible to the intent")
        }
    }
}
