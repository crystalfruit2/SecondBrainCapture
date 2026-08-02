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
    @Published private(set) var hasToken: Bool

    init() {
        let d = UserDefaults.standard
        owner = d.string(forKey: "owner") ?? "crystalfruit2"
        repo = d.string(forKey: "repo") ?? "second_brain"
        branch = d.string(forKey: "branch") ?? "main"
        folder = d.string(forKey: "folder") ?? "Inbox"
        dashboardPath = d.string(forKey: "dashboardPath") ?? "dashboard.json"
        marketListPath = d.string(forKey: "marketListPath") ?? "Areas/Market-List.md"
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
