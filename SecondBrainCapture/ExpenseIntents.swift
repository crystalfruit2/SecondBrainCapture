import AppIntents
import UserNotifications

/// "Log Expense" — the action the Shortcuts **Wallet / Transaction**
/// automation runs on every Apple Pay tap. iOS lets no app read another
/// app's notifications, so this is how a card payment reaches the vault: the
/// automation hands over Amount, Merchant and Card from its Shortcut Input.
///
/// Every parameter is optional text on purpose:
/// - Wallet sometimes delivers no input at all, and a required parameter with
///   nothing in it stops the automation with a prompt nobody sees.
/// - Amount arrives as currency text in the phone's locale ("4,50 €"), and
///   Shortcuts' own text→number conversion is unreliable for it — the app
///   parses it and keeps the text it was given.
///
/// Runs in the background, also while the phone is locked (the default
/// authentication policy allows it). It is listed in Shortcuts automatically;
/// no `AppShortcut` is needed for an action that only an automation calls.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Expense"
    static var description = IntentDescription(
        "Records a payment in your vault. Use it in a Wallet (Transaction) automation and fill Amount, Merchant and Card from Shortcut Input.",
        categoryName: "Finance"
    )

    @Parameter(title: "Amount", description: "As text, e.g. Shortcut Input ▸ Amount (\"4,50 €\").")
    var amount: String?

    @Parameter(title: "Merchant", description: "Shortcut Input ▸ Merchant.")
    var merchant: String?

    @Parameter(title: "Card", description: "Shortcut Input ▸ Card or Pass.")
    var card: String?

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") {
            \.$card
            \.$note
        }
    }

    /// Hard ceiling for the upload. The system gives a background intent
    /// about 30 s; the expense is already on disk before this starts, so
    /// giving up early costs nothing — the next tap or app open sends it.
    private static let uploadCeiling: TimeInterval = 20
    /// A payment still unsent after this long means sync is broken (an
    /// expired token), not that a shop had no signal.
    private static let stuckAfter: TimeInterval = 12 * 3600

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let entry = await ExpenseStore.shared.record(rawAmount: amount ?? "",
                                                     merchant: merchant ?? "",
                                                     card: card ?? "",
                                                     note: note ?? "")
        await Self.flush(within: Self.uploadCeiling)

        let store = await ExpenseStore.shared
        let synced = await store.isSynced(entry.id)
        if !synced, !(await store.lastSaveSucceeded) {
            // Neither on disk nor in the vault: say so, so Shortcuts reports
            // the automation as failed instead of a silent loss.
            throw ExpenseLogError.notSaved
        }
        if let oldest = await store.oldestPending, Date().timeIntervalSince(oldest) > Self.stuckAfter {
            await Self.warnAboutBacklog(await store.pendingCount)
        }
        return .result(value: entry.summaryLine)
    }

    /// Upload with a wall-clock limit: the request timeout only bounds idle
    /// time, so a trickling connection is cut off by cancelling the task.
    private static func flush(within seconds: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await ExpenseStore.shared.flush(requestTimeout: 8,
                                                deadline: Date().addingTimeInterval(seconds - 8))
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// One banner (same identifier, so it replaces itself) that opens Finance,
    /// where the reason is shown. Does nothing if notifications are off.
    private static func warnAboutBacklog(_ count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "1 payment hasn't reached your vault" : "\(count) payments haven't reached your vault"
        content.body = "Open Rocky's Vault ▸ Features ▸ Finance to see why."
        content.userInfo = ["tab": "finance"]
        let request = UNNotificationRequest(identifier: "expense.backlog", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

enum ExpenseLogError: Error, CustomLocalizedStringResourceConvertible {
    case notSaved

    var localizedStringResource: LocalizedStringResource {
        "Rocky's Vault could not save this payment on the phone or send it to the vault."
    }
}
