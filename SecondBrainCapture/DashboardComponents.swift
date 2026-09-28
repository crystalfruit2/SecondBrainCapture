import SwiftUI

/// The shared visual vocabulary of the dashboard tabs.
///
/// Everything here leans on system colours (`secondarySystemGroupedBackground`,
/// `.tint`, `.secondary`) rather than hard-coded hex, so the new screens inherit
/// exactly the look the Capture screen already had — and stay native if iOS
/// changes its palette underneath us.

// MARK: - Section header

/// `Overdue 1` / `Today 2` — a grouped-list header with an optional count.
struct SectionHeader: View {
    let title: String
    var count: Int?
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            if let count {
                Text("\(count)")
                    .monospacedDigit()
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 7)
    }
}

// MARK: - Task row

struct TaskPill: View {
    let text: String
    let style: PillStyle

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch style {
        case .overdue: return .orange
        case .project: return .secondary
        case .date: return .secondary
        }
    }

    private var background: Color {
        switch style {
        case .overdue: return .orange.opacity(0.16)
        case .project: return Color(.tertiarySystemGroupedBackground)
        case .date: return .clear
        }
    }
}

struct TaskRow: View {
    let task: DashboardTask
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                checkbox
            }
            .buttonStyle(.plain)
            // The tap target is the row's whole left edge, not just the 22pt circle.
            .contentShape(Rectangle())

            Text(task.text)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(task.done ? Color.secondary : Color.primary)
                .strikethrough(task.done, color: .secondary)
                .lineLimit(3)

            Spacer(minLength: 8)

            if let pill = task.trailingPill {
                TaskPill(text: pill.text, style: pill.style)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.snappy(duration: 0.2), value: task.done)
    }

    private var checkbox: some View {
        ZStack {
            if task.done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(task.bucket == .upcoming ? Color.secondary.opacity(0.45) : Color.accentColor,
                                  lineWidth: 2)
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Market row

/// A market item's checkbox has no bucket/pill logic to carry — it's the
/// plainest row in the app on purpose.
struct MarketRow: View {
    let item: MarketItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                checkbox
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Text(item.text)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(item.done ? Color.secondary : Color.primary)
                .strikethrough(item.done, color: .secondary)
                .lineLimit(3)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.snappy(duration: 0.2), value: item.done)
    }

    private var checkbox: some View {
        ZStack {
            if item.done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Rocky card

/// The Companion showing up when Alp is *not* in a Claude session — one card,
/// one nudge, the thing he'd otherwise miss.
///
/// The phone can't actually run a review or process the Inbox itself — it's a
/// dumb sponge, all real work happens vault-side in a Claude session. So a tap
/// on an actionable nudge (`onTap != nil`) doesn't "run" anything directly; it
/// queues a capture through the same durable `CaptureQueue` every note goes
/// through, which the next Claude session picks up and actually acts on.
struct RockyCard: View {
    let nudge: RockyNudge
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image("RockyMascot")
                .resizable()
                .scaledToFit()
                .padding(3)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("ROCKY")
                    .font(.caption2.weight(.bold))
                    .kerning(0.6)
                    .foregroundStyle(Color.accentColor)
                Text(nudge.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Agenda row

struct AgendaRow: View {
    let item: AgendaItem

    var body: some View {
        HStack(spacing: 12) {
            Text(item.time)
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, alignment: .leading)

            Text(item.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - States

/// Shown before the first successful fetch, or when there is genuinely nothing
/// to act on. Distinguishes "not set up yet" from "all clear" — they need very
/// different responses from Alp.
struct DashboardPlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 56)
    }
}

/// Thin banner for a sync problem that shouldn't take over the screen — the
/// cached board underneath is still useful.
struct DashboardErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "3 edits waiting to sync" — the read-side twin of the capture queue's badge.
struct PendingSyncBadge: View {
    let count: Int

    var body: some View {
        Label("^[\(count) edit](inflect: true) waiting to sync…", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - To-do row

/// One line of Alp's own list. Same anatomy as `TaskRow`, but done-ness comes
/// from `isDone()` (routines: today's / this week's ✅ stamp) and the trailing
/// pill shows what matters for a personal item: how late, or when.
struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void

    private var done: Bool { item.isDone() }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) { checkbox }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .strikethrough(done, color: .secondary)
                    .lineLimit(2)
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if let pill { TaskPill(text: pill.text, style: pill.style) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.snappy(duration: 0.2), value: done)
    }

    /// A weekly routine remembers when it was last done — useful context that
    /// a daily one doesn't need.
    private var subtitle: String? {
        guard item.recur == .weekly, let last = item.lastDoneDate else { return nil }
        return "Last " + last.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var pill: (text: String, style: PillStyle)? {
        if item.recur != nil { return nil }
        switch item.bucket() {
        case .overdue(let days):
            return (days == 1 ? "1 day late" : "\(days) days late", .overdue)
        case .today:
            return item.time.map { ($0, .date) }
        case .thisWeek:
            guard let d = item.dueDate else { return nil }
            var s = d.formatted(.dateTime.weekday(.abbreviated))
            if let t = item.time { s += " \(t)" }
            return (s, .date)
        case .later:
            guard let d = item.dueDate else { return nil }
            return (d.formatted(.dateTime.day().month(.abbreviated)), .date)
        case .anytime:
            return nil
        }
    }

    private var checkbox: some View {
        ZStack {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else if item.recur != nil {
                Image(systemName: "repeat.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.accentColor)
            } else {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Vault task row (trimmed, expandable)

/// A Daily-note task cut to its first clause; tapping the row expands to the
/// full Claude-written line. The checkbox still toggles the vault line.
struct VaultTaskRow: View {
    let task: DashboardTask
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) { checkbox }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 4) {
                Text(expanded ? task.text : task.shortText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(task.done ? Color.secondary : Color.primary)
                    .strikethrough(task.done, color: .secondary)
                    .lineLimit(expanded ? nil : 2)
                if !expanded, task.isTruncated {
                    Text("more…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            // Project names inferred from a "Name: …" prefix can run long; a
            // pill wider than the text it decorates is noise on this row.
            if let pill = task.trailingPill, pill.style != .project || pill.text.count <= 14 {
                TaskPill(text: pill.text, style: pill.style)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.snappy(duration: 0.2), value: task.done)
    }

    private var checkbox: some View {
        ZStack {
            if task.done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .strokeBorder(task.bucket == .upcoming ? Color.secondary.opacity(0.45) : Color.accentColor,
                                  lineWidth: 2)
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 22, height: 22)
        .padding(.top, 1)
    }
}
