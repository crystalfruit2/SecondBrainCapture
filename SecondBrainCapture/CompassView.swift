import SwiftUI

/// Compass (2026-11-08): what to give time to — **now**, **today** and **this
/// week**. The vault engine computes everything (`compass` key, schema v7);
/// this screen only renders it and logs time back. Kept deliberately terse:
/// one headline, one Now card, a timeline, a bar per area, and two collapsed
/// lists. Entry points: the Now card on the To Do tab, the Compass segment in
/// Features, and `-sbcOpenCompass` (DEBUG) for simulator screenshots.
struct CompassScreen: View {
    var body: some View {
        CompassContent(logPlacement: .topBarTrailing)
            .navigationTitle("Compass")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
    }
}

/// Content only (no NavigationStack), like `FinanceContent`, so it can live
/// inside the Features shell or be pushed from To Do.
struct CompassContent: View {
    @EnvironmentObject var store: DashboardStore
    var logPlacement: ToolbarItemPlacement = .topBarTrailing
    @State private var draft: CompassLogDraft?
    @State private var feedback = 0

    var body: some View {
        Group {
            if let payload = store.dashboard?.compass {
                TimelineView(.everyMinute) { context in
                    CompassList(payload: payload, now: context.date,
                                loggedSlots: store.compassLoggedSlots(now: context.date)) { draft = $0 }
                }
            } else {
                DashboardPlaceholder(icon: "safari",
                                     title: "No Compass yet",
                                     message: "Compass shows up once the vault's dashboard carries it. The vault note is Areas/Compass.md.")
            }
        }
        .toolbar {
            if let payload = store.dashboard?.compass, !payload.areas.isEmpty {
                ToolbarItem(placement: logPlacement) {
                    Button { draft = CompassLogDraft(area: defaultArea(payload), minutes: 60) } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Log time")
                }
            }
        }
        .sheet(item: $draft) { d in
            CompassLogSheet(areas: store.dashboard?.compass?.areas ?? [], draft: d) { area, minutes, note in
                store.logCompass(areaId: area, minutes: minutes, note: note, slotID: d.slotID)
                feedback += 1
            }
        }
        .sensoryFeedback(.success, trigger: feedback)
        .onAppear {
            #if DEBUG
            // `… -sbcOpenCompass -sbcCompassLog` opens the log sheet (screenshots only).
            if CommandLine.arguments.contains("-sbcCompassLog"), let p = store.dashboard?.compass {
                draft = CompassLogDraft(area: defaultArea(p), minutes: 60)
            }
            #endif
        }
    }

    /// The area of whatever is on now (or next), else the first area.
    private func defaultArea(_ p: CompassPayload) -> String {
        switch CompassClock.pick(p, now: Date()) {
        case .current(let s), .next(let s):
            if let a = s.area, p.area(a) != nil { return a }
        case .done: break
        }
        return p.areas.first?.id ?? ""
    }
}

private struct CompassList: View {
    @EnvironmentObject var store: DashboardStore
    let payload: CompassPayload
    let now: Date
    let loggedSlots: Set<String>
    let onLog: (CompassLogDraft) -> Void
    @State private var expanded: Set<String> = []
    @State private var showTop = false
    @State private var showLetGo = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onAppear {
                    #if DEBUG
                    // Screenshots of the lower half: `… -sbcOpenCompass -sbcCompassScroll`
                    if CommandLine.arguments.contains("-sbcCompassScroll") {
                        showTop = true; showLetGo = true
                        let args = CommandLine.arguments
                        let target = args.firstIndex(of: "-sbcCompassScroll").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                        let id = target == "ranked" ? "ranked" : "week"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(id, anchor: .top) }
                    }
                    #endif
                }
        }
    }

    @ViewBuilder private var list: some View {
        let nowMin = CompassClock.nowMinutes(now)
        let isToday = payload.date == CompassClock.today(now)
        let pick = CompassClock.pick(payload, now: now)
        List {
            if store.compassPendingCount > 0 || store.lastError != nil {
                Section {
                    if store.compassPendingCount > 0 {
                        PendingSyncBadge(count: store.compassPendingCount, noun: "log")
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if let error = store.lastError {
                        DashboardErrorBanner(message: error)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
            }

            // Headline + Now
            Section {
                if let headline = payload.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
                        .listRowSeparator(.hidden)
                }
                CompassNowCard(payload: payload, now: now, compact: false)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Today
            let timeline = payload.timeline
            if !timeline.isEmpty {
                Section {
                    ForEach(timeline) { slot in
                        let live: Bool = { if case .current(let s) = pick { return s.id == slot.id }; return false }()
                        CompassTimelineRow(slot: slot, area: payload.area(slot.area),
                                           live: live,
                                           past: isToday ? slot.hasEnded(at: nowMin) : payload.date < CompassClock.today(now),
                                           expanded: expanded.contains(slot.id),
                                           canMarkDone: !loggedSlots.contains(slot.id)
                                               && payload.area(slot.area) != nil
                                               && CompassClock.canMarkDone(slot, payload: payload, now: now),
                                           logged: loggedSlots.contains(slot.id)) {
                            onLog(CompassLogDraft(area: slot.area ?? "", minutes: max(15, slot.minutes), slotID: slot.id))
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(live ? CompassTint.color(slot.area).opacity(0.12)
                                                : Color(.secondarySystemGroupedBackground))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !slot.why.isEmpty else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                if expanded.contains(slot.id) { expanded.remove(slot.id) } else { expanded.insert(slot.id) }
                            }
                        }
                    }
                } header: {
                    SectionHeader(title: "Today").textCase(nil)
                }
            }

            // This week
            if !payload.areas.isEmpty {
                Section {
                    if let cap = payload.capacity {
                        HStack(spacing: 6) {
                            Image(systemName: cap.isOverbooked ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                            Text(CompassFormat.capacity(cap))
                        }
                            .font(.caption)
                            .foregroundStyle(cap.isOverbooked ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    ForEach(payload.areas) { area in
                        CompassWeekRow(area: area)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    SectionHeader(title: "This week").textCase(nil)
                }
                .id("week")
            }

            // Ranked + Let go
            if !payload.top.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showTop) {
                        ForEach(Array(payload.top.enumerated()), id: \.element.id) { i, item in
                            CompassRankedRow(rank: i + 1, item: item, area: payload.area(item.area))
                        }
                    } label: {
                        Label("Top \(payload.top.count)", systemImage: "list.number")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .id("ranked")
            }
            if !payload.letGo.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showLetGo) {
                        ForEach(payload.letGo) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline)
                                if !item.reason.isEmpty {
                                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } label: {
                        Label("Let go? \(payload.letGo.count)", systemImage: "leaf")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if let generated = payload.generatedAt {
                Section {
                    Text("Compass built \(generated.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .refreshable { await store.refresh() }
    }
}

// MARK: - Now card

/// What to be doing right now. `compact` is the one-row version that sits at
/// the top of the To Do tab.
struct CompassNowCard: View {
    let payload: CompassPayload
    let now: Date
    var compact = false

    private var pick: CompassNow { CompassClock.pick(payload, now: now) }
    private var stale: Bool { CompassClock.isStale(payload, now: now) }

    var body: some View {
        switch pick {
        case .current(let s): card(label: "NOW", slot: s)
        case .next(let s): card(label: "NEXT", slot: s)
        case .done: doneCard
        }
    }

    private func card(label: String, slot: CompassSlot) -> some View {
        let area = payload.area(slot.area)
        let tint = slot.isFixed ? Color.secondary : CompassTint.color(slot.area)
        return HStack(alignment: compact ? .center : .top, spacing: 12) {
            Text(area?.emoji ?? (slot.isFixed ? "🔒" : "•"))
                .font(compact ? .title3 : .title2)
                .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                HStack(spacing: 6) {
                    Text("\(label) · \(slot.timeLabel)")
                        .font(.caption2.weight(.bold))
                        .kerning(0.4)
                        .monospacedDigit()
                        .foregroundStyle(slot.isFixed ? Color.secondary : tint)
                    if slot.isFixed {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(CompassFormat.dropLeadingEmoji(slot.title))
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    ForEach(slot.why, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if stale { staleNote }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var doneCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(compact ? .title3 : .title2)
                .foregroundStyle(.green)
                .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("COMPASS")
                    .font(.caption2.weight(.bold)).kerning(0.4).foregroundStyle(.secondary)
                Text("Day's plan is done")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                if stale { staleNote }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var staleNote: some View {
        Text("stale — computed for \(CompassFormat.shortDay(payload.date))")
            .font(.caption2)
            .foregroundStyle(.orange)
    }
}

// MARK: - Rows

private struct CompassTimelineRow: View {
    let slot: CompassSlot
    let area: CompassArea?
    let live: Bool
    let past: Bool
    let expanded: Bool
    let canMarkDone: Bool
    let logged: Bool
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.start).font(.footnote.weight(.bold))
                if let end = slot.end { Text(end).font(.caption2).foregroundStyle(.secondary) }
            }
            .monospacedDigit()
            .foregroundStyle(slot.isFixed ? Color.secondary : Color.primary)
            .frame(width: 42, alignment: .leading)

            Capsule()
                .fill(slot.isFixed ? Color(.tertiaryLabel) : CompassTint.color(slot.area))
                .frame(width: 4)
                .frame(minHeight: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if slot.isFixed {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                    // One emoji per row: the engine's own, else the area's.
                    if let first = slot.title.first, CompassFormat.isEmoji(first) {
                    } else if !slot.isFixed, let emoji = area?.emoji {
                        Text(emoji).font(.subheadline)
                    }
                    Text(slot.title)
                        .font(.subheadline.weight(slot.isFixed ? .regular : .medium))
                        .foregroundStyle(slot.isFixed ? Color.secondary : Color.primary)
                        .lineLimit(expanded ? 3 : 1)
                }
                if expanded {
                    ForEach(slot.why, id: \.self) { line in
                        Text("· \(line)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !slot.isFixed || canMarkDone {
                    HStack(spacing: 8) {
                        if !slot.isFixed && !expanded {
                            Text("\(slot.minutes) min").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if canMarkDone {
                            Button(action: onDone) {
                                Text("✓ Done")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .foregroundStyle(.green)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if logged {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if live {
                Text("now")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(slot.isFixed ? Color.secondary : CompassTint.color(slot.area))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .opacity(past && !canMarkDone && !logged ? 0.5 : 1)
    }
}

private struct CompassWeekRow: View {
    let area: CompassArea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(area.emoji)
                Text(area.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                CompassStatusChip(status: area.statusKind)
            }
            HStack(spacing: 10) {
                CompassBar(progress: area.progress, floor: area.floorFraction,
                           tint: CompassTint.color(area.id), hasTarget: area.targetMin > 0)
                Text(CompassFormat.progress(area))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .trailing)
            }
            if area.next != nil || area.deadlineLabel != nil {
                HStack(spacing: 8) {
                    if let next = area.next {
                        Text(next).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let label = area.deadlineLabel {
                        HStack(spacing: 3) {
                            Image(systemName: "calendar")
                            Text(label).lineLimit(1)
                        }
                        .foregroundStyle(.orange)
                        .fixedSize()
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Thin capsule from 0 to the weekly target, with a tick at the floor.
private struct CompassBar: View {
    let progress: Double
    let floor: Double
    let tint: Color
    let hasTarget: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 6)
                Capsule().fill(tint).frame(width: max(progress > 0 ? 6 : 0, w * progress), height: 6)
                if hasTarget && floor > 0 && floor < 1 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 11)
                        .offset(x: w * floor - 1)
                }
            }
            .frame(height: 11)
        }
        .frame(height: 11)
        .animation(.snappy(duration: 0.35), value: progress)
        .accessibilityHidden(true)
    }
}

struct CompassStatusChip: View {
    let status: CompassStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch status.tone {
        case .good: return .green
        case .neutral: return .blue
        case .warn: return .orange
        case .bad: return .red
        case .muted: return .gray
        }
    }
}

private struct CompassRankedRow: View {
    let rank: Int
    let item: CompassItem
    let area: CompassArea?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(item.score)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(CompassTint.color(item.area))
                .frame(width: 30, height: 22)
                .background(CompassTint.color(item.area).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        var parts: [String] = []
        if let emoji = area?.emoji { parts.append(emoji) }
        if let due = item.due { parts.append("due \(CompassFormat.shortDay(due))") }
        parts.append(contentsOf: item.why.filter { !$0.hasPrefix("due ") || item.due == nil })
        return parts.joined(separator: " · ")
    }
}

// MARK: - Log sheet

struct CompassLogDraft: Identifiable {
    let id = UUID()
    var area: String
    var minutes: Int
    var slotID: String? = nil
}

struct CompassLogSheet: View {
    let areas: [CompassArea]
    let onSave: (String, Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var area: String
    @State private var minutes: Int
    @State private var note = ""

    init(areas: [CompassArea], draft: CompassLogDraft, onSave: @escaping (String, Int, String) -> Void) {
        self.areas = areas
        self.onSave = onSave
        _area = State(initialValue: areas.contains { $0.id == draft.area } ? draft.area : (areas.first?.id ?? ""))
        _minutes = State(initialValue: draft.minutes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Area", selection: $area) {
                        ForEach(areas) { a in Text("\(a.emoji) \(a.name)").tag(a.id) }
                    }
                }
                Section("Time") {
                    HStack(spacing: 6) {
                        ForEach(CompassLog.chips, id: \.self) { m in
                            Button { minutes = m } label: {
                                Text(m < 60 || m % 60 != 0 ? "\(m)" : "\(m / 60)h")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(minutes == m ? Color.white : Color.primary)
                                    .background(minutes == m ? Color.accentColor : Color(.tertiarySystemFill),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Stepper(value: $minutes, in: 5...600, step: 5) {
                        Text("\(minutes) min").monospacedDigit()
                    }
                }
                Section("Note") {
                    TextField(CompassLog.defaultNote, text: $note)
                }
            }
            .navigationTitle("Log time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(area, minutes, note)
                        dismiss()
                    }
                    .disabled(area.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Area colours

enum CompassTint {
    private static let known: [String: Color] = [
        "opt": .blue, "apc": .purple, "rl": .teal, "prml": .indigo, "deutsch": .orange,
        "sport": .green, "summer27": .red, "rocky": .mint, "nudge": .cyan, "admin": .brown,
    ]
    private static let palette: [Color] = [.blue, .purple, .teal, .indigo, .orange, .green, .pink, .mint, .cyan, .brown]

    /// Stable per area id (String.hashValue is seeded per launch, so not that).
    static func color(_ id: String?) -> Color {
        guard let id, !id.isEmpty else { return .secondary }
        if let c = known[id] { return c }
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}
