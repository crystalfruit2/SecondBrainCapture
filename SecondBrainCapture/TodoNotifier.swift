import Foundation
import UserNotifications

/// Local reminders for the To Do list — no server, no APNs. Everything is
/// scheduled on-device from the cached dashboard and rescheduled whenever the
/// list changes or the app comes to the foreground, so the digest text is at
/// most one refresh stale.
///
/// Three kinds, all under the `todo.` identifier prefix so the Sentinel's APNs
/// pushes (Finance) are never touched:
///   • `todo.item.<id>`      — a dated one-off or errand, at its ⏰ time or the
///                            digest hour on its due day
///   • `todo.digest.daily`   — "N routines · M due today", every morning
///   • `todo.digest.weekly`  — Monday morning's week-ahead line
@MainActor
final class TodoNotifier {
    static let shared = TodoNotifier()
    static let prefix = "todo."
    /// iOS keeps at most 64 pending local notifications per app; leave room
    /// for the two digests and anything else the app schedules.
    private let itemCap = 50

    func reschedule(items: [TodoItem], enabled: Bool, digestMinutes: Int, now: Date = Date()) async {
        #if DEBUG
        // Simulator screenshots must not be blocked by the permission alert.
        if CommandLine.arguments.contains("-sbcTodoSegment") { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard enabled, !items.isEmpty else { return }

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        guard await center.notificationSettings().authorizationStatus != .denied else { return }

        var requests: [UNNotificationRequest] = []

        // Dated one-offs and errands.
        let dated = items
            .filter { $0.recur == nil && !$0.isDone(on: now) }
            .compactMap { item -> (TodoItem, Date)? in
                guard let fire = item.reminderDate(defaultMinutes: digestMinutes), fire > now else { return nil }
                return (item, fire)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(itemCap)
        for (item, fire) in dated {
            let content = UNMutableNotificationContent()
            content.title = item.section == .errand ? "Errand" : "To do"
            content.body = item.text
            content.sound = .default
            content.userInfo = ["tab": "todo"]
            content.threadIdentifier = "todo"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            requests.append(UNNotificationRequest(identifier: Self.prefix + "item." + item.id,
                                                  content: content,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }

        // Morning digest — for the *next* digest moment, with that day's counts.
        if let digestAt = nextOccurrence(ofMinutes: digestMinutes, after: now) {
            let routines = items.filter { $0.recur == .daily }.count
            let due = items.filter { $0.recur == nil && !$0.isDone(on: digestAt) }
                .filter { if case .later = $0.bucket(on: digestAt) { return false }; return $0.dueDate != nil }
                .count
            if routines + due > 0 {
                let content = UNMutableNotificationContent()
                content.title = "Good morning"
                var parts: [String] = []
                if routines > 0 { parts.append(routines == 1 ? "1 routine" : "\(routines) routines") }
                if due > 0 { parts.append(due == 1 ? "1 thing due today" : "\(due) things due today") }
                content.body = parts.joined(separator: " · ")
                content.sound = .default
                content.userInfo = ["tab": "todo"]
                content.threadIdentifier = "todo"
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: digestAt)
                requests.append(UNNotificationRequest(identifier: Self.prefix + "digest.daily", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }

        // Monday digest — the week ahead.
        if let monday = TodoClock.nextMonday(after: now, atMinutes: digestMinutes) {
            let weekly = items.filter { $0.recur == .weekly }.count
            let thisWeek = items.filter { item in
                guard item.recur == nil, !item.isDone(on: monday), let d = item.dueDate else { return false }
                return TodoClock.isSameISOWeek(d, monday) || d < monday
            }.count
            if weekly + thisWeek > 0 {
                let content = UNMutableNotificationContent()
                content.title = "This week"
                var parts: [String] = []
                if weekly > 0 { parts.append(weekly == 1 ? "1 weekly routine" : "\(weekly) weekly routines") }
                if thisWeek > 0 { parts.append(thisWeek == 1 ? "1 dated to-do" : "\(thisWeek) dated to-dos") }
                content.body = parts.joined(separator: " · ")
                content.sound = .default
                content.userInfo = ["tab": "todo"]
                content.threadIdentifier = "todo"
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: monday)
                requests.append(UNNotificationRequest(identifier: Self.prefix + "digest.weekly", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }

        for request in requests {
            try? await center.add(request)
        }
    }

    /// Today at `minutes` past midnight if that's still ahead, else tomorrow.
    private func nextOccurrence(ofMinutes minutes: Int, after now: Date) -> Date? {
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now) else { return nil }
        if today > now { return today }
        return cal.date(byAdding: .day, value: 1, to: today)
    }
}
