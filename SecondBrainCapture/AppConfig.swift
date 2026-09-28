import Foundation
import Combine

/// Holds repo configuration (persisted in UserDefaults) and the GitHub token
/// (persisted securely in the Keychain). Defaults are pre-filled for Alp's vault.
@MainActor
final class AppConfig: ObservableObject {
    @Published var owner: String { didSet { UserDefaults.standard.set(owner, forKey: "owner") } }
    @Published var repo: String { didSet { UserDefaults.standard.set(repo, forKey: "repo") } }
    @Published var branch: String { didSet { UserDefaults.standard.set(branch, forKey: "branch") } }
    @Published var folder: String { didSet { UserDefaults.standard.set(folder, forKey: "folder") } }
    /// Repo-relative path of the prebuilt dashboard the vault's GitHub Action writes.
    @Published var dashboardPath: String { didSet { UserDefaults.standard.set(dashboardPath, forKey: "dashboardPath") } }
    /// Repo-relative path of the market list note — a plain checklist, read via
    /// `dashboard.json` but written to directly (append/toggle).
    @Published var marketListPath: String { didSet { UserDefaults.standard.set(marketListPath, forKey: "marketListPath") } }
    /// Repo-relative path of the To-Do list note (schema v4). Same contract as
    /// the market list: read via the dashboard, written to directly.
    @Published var todoListPath: String { didSet { UserDefaults.standard.set(todoListPath, forKey: "todoListPath") } }
    /// Local To-Do reminders (dated items + morning/Monday digests).
    @Published var remindersEnabled: Bool { didSet { UserDefaults.standard.set(remindersEnabled, forKey: "remindersEnabled") } }
    /// Minutes past midnight for the daily digest and for dated items with no ⏰ time. Default 08:30.
    @Published var digestMinutes: Int { didSet { UserDefaults.standard.set(digestMinutes, forKey: "digestMinutes") } }
    @Published private(set) var hasToken: Bool

    init() {
        let d = UserDefaults.standard
        owner = d.string(forKey: "owner") ?? "crystalfruit2"
        repo = d.string(forKey: "repo") ?? "second_brain"
        branch = d.string(forKey: "branch") ?? "main"
        folder = d.string(forKey: "folder") ?? "Inbox"
        dashboardPath = d.string(forKey: "dashboardPath") ?? "dashboard.json"
        marketListPath = d.string(forKey: "marketListPath") ?? "Areas/Market-List.md"
        todoListPath = d.string(forKey: "todoListPath") ?? "Areas/To-Do.md"
        remindersEnabled = d.object(forKey: "remindersEnabled") as? Bool ?? true
        digestMinutes = d.object(forKey: "digestMinutes") as? Int ?? (8 * 60 + 30)
        hasToken = KeychainStore.loadToken() != nil
    }

    var token: String { KeychainStore.loadToken() ?? "" }

    func setToken(_ newToken: String) {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.deleteToken()
        } else {
            KeychainStore.saveToken(trimmed)
        }
        hasToken = KeychainStore.loadToken() != nil
    }

    var githubConfig: GitHubConfig {
        GitHubConfig(owner: owner, repo: repo, branch: branch, folder: folder)
    }
}
