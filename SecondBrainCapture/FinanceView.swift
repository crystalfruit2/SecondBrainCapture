import SwiftUI

/// Finance segment — the phone's read-only window onto `/finance` (Faz 0: data
/// and the record, never an order). Everything comes from `dashboard.json.finance`;
/// nothing here writes, and no number is parsed — Turkish-formatted strings are
/// shown exactly as the vault wrote them.
struct FinanceContent: View {
    @EnvironmentObject var store: DashboardStore

    private var finance: FinancePayload? { store.dashboard?.finance }

    var body: some View {
        List {
            if let finance, !finance.isEmpty {
                if let sentinel = finance.sentinel { sentinelSections(sentinel) }
                headerSection(finance)
                rulesSection(finance)
                sicilSection(finance)
                calendarSection(finance)
                briefSection(finance)
                Section {
                    Text("Faz 0 — data and record only. Source: \(finance.source ?? "Areas/Finance.md") via /finance.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    DashboardPlaceholder(icon: "turkishlirasign.circle",
                                         title: "No finance data",
                                         message: "The vault hasn't shipped a finance block yet — run /finance sync on the Mac, then pull down.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    // MARK: sections

    /// Faz S-G4a — the cloud Sentinel: today's close card, unread alerts, watcher health.
    /// Verbatim text from the watcher (rule-card wording); no buttons, no orders.
    @ViewBuilder
    private func sentinelSections(_ s: FinanceSentinel) -> some View {
        if let card = s.card {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.title)
                            .font(.headline)
                            .foregroundStyle(card.notify ? .orange : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if card.stale { TaskPill(text: "bayat", style: .overdue) }
                    }
                    ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                SectionHeader(title: "Kapanış kartı" + (card.date.map { " · \($0)" } ?? "")).textCase(nil)
            }
        }
        if !s.alerts.isEmpty {
            Section {
                ForEach(s.alerts) { a in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if !a.msg.isEmpty {
                            Text(a.msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let ts = a.ts { Text(ts.prefix(16).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SectionHeader(title: "Okunmamış uyarılar", count: s.alerts.count, tint: .orange).textCase(nil)
            } footer: {
                Text("Okundu: Mac'te /finance monitor ack. Karar Alp'in.").font(.caption2)
            }
        }
        Section {
            HStack(spacing: 6) {
                Image(systemName: (s.failures + s.pushFailures) > 0 || s.watchStale ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle((s.failures + s.pushFailures) > 0 || s.watchStale ? .orange : .green)
                Text(sentinelStatus(s)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sentinelStatus(_ s: FinanceSentinel) -> String {
        var parts = ["izleyici " + (s.checkedAt.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "—")]
        if s.failures > 0 { parts.append("\(s.failures) fiyat hatası") }
        if s.pushFailures > 0 { parts.append("\(s.pushFailures) bildirim hatası") }
        if s.watchStale { parts.append("watch.json bayat — Mac'te bir Claude oturumu aç") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func headerSection(_ f: FinancePayload) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(cell(f.latest, "Portföy TL"))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text("TL").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let d = f.latest?.date, !d.isEmpty {
                        TaskPill(text: "§Sicil \(d)", style: .date)
                    }
                }
                if let record = f.blocks["record"], let first = record.split(separator: "\n").first {
                    Text(String(first))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let cols = f.sicilColumns.filter { !["Tarih", "Portföy TL", "Not"].contains($0) }
                if !cols.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(cols, id: \.self) { c in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                Text(cell(f.latest, c)).font(.caption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(isBlank(cell(f.latest, c)) ? .tertiary : .primary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private func rulesSection(_ f: FinancePayload) -> some View {
        let rules = FinanceParser.rules(from: f.blocks["rules"] ?? "")
        if !rules.isEmpty {
            Section {
                ForEach(rules) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(r.isFired ? "●" : (r.status == .info ? "○" : "·"))
                            .font(.caption)
                            .foregroundStyle(r.isFired ? Color.orange : Color.secondary)
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.id)
                                .font(.caption.weight(.semibold).monospaced())
                                .foregroundStyle(r.isFired ? .primary : .secondary)
                            Text(r.measure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if r.isFired {
                            TaskPill(text: r.task == "evet" ? "task" : "fired", style: .overdue)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(r.isFired ? Color.orange.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                }
            } header: {
                SectionHeader(title: "Rules", count: rules.filter(\.isFired).count).textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func sicilSection(_ f: FinancePayload) -> some View {
        if !f.sicil.isEmpty {
            let cols = f.sicilColumns.filter { $0 != "Not" }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(cols, id: \.self) { c in
                                Text(c).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Divider()
                        ForEach(f.newestFirst) { row in
                            GridRow {
                                ForEach(cols, id: \.self) { c in
                                    let v = row.cells[c] ?? "—"
                                    Text(v)
                                        .font(.caption)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .foregroundStyle(isBlank(v) ? .tertiary : (row.id == f.latest?.id ? .primary : .secondary))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .listRowInsets(EdgeInsets())
                if let note = f.latest?.cells["Not"], !isBlank(note) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: "Sicil · weekly", count: f.sicil.count).textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func calendarSection(_ f: FinancePayload) -> some View {
        let entries = FinanceParser.calendar(from: f.blocks["calendar"] ?? "")
        if !entries.isEmpty {
            Section {
                ForEach(entries.prefix(8)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.date)
                            .font(.footnote.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                        Text(e.what)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let d = e.daysAway {
                            TaskPill(text: d >= 0 ? "+\(d) d" : "\(d) d", style: .date)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: "Calendar").textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func briefSection(_ f: FinancePayload) -> some View {
        if let brief = f.brief {
            let sections = FinanceParser.briefSections(from: brief.markdown)
            Section {
                ForEach(sections) { s in
                    VStack(alignment: .leading, spacing: 5) {
                        if !s.title.isEmpty {
                            Text(s.title).font(.subheadline.weight(.semibold))
                        }
                        let tableLines = s.body.split(separator: "\n").map(String.init).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
                        let proseLines = s.body.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
                        let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !prose.isEmpty {
                            Text(inline(prose))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !tableLines.isEmpty {
                            let t = FinanceParser.table(from: tableLines)
                            ScrollView(.horizontal, showsIndicators: false) {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                    GridRow {
                                        ForEach(Array(t.header.enumerated()), id: \.offset) { _, h in
                                            Text(h).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                    }
                                    ForEach(Array(t.rows.enumerated()), id: \.offset) { _, row in
                                        GridRow {
                                            ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                                                Text(inline(v)).font(.caption2).monospacedDigit().lineLimit(1)
                                                    .foregroundStyle(isBlank(v) ? .tertiary : .primary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .listRowInsets(EdgeInsets())
                }
            } header: {
                SectionHeader(title: "Brief · \(brief.date)").textCase(nil)
            }
        }
    }

    // MARK: helpers

    private func cell(_ row: SicilRow?, _ column: String) -> String {
        row?.cells[column] ?? "—"
    }

    private func isBlank(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "—" || t == "-"
    }

    /// Inline markdown (bold / code) via Foundation only — no library, matches how
    /// the rest of the app avoids dependencies.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

#Preview {
    NavigationStack { FinanceContent() }
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
