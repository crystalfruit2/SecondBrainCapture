import SwiftUI
import UserNotifications
import CryptoKit

/// Faz S-G4a — real phone notifications from the vault's Sentinel Action (APNs,
/// no third-party app). The phone's only job: ask permission, hand its device
/// token to the vault, and open Finance when a banner is tapped. The banner
/// text is decided server-side (the alert title — rule-card wording, never an
/// order); nothing here writes anything else.
///
/// Token file: `Areas/Finance/monitor/devices/<env>-<sha8>.json`, one file per
/// token, created once (`putNewFile` treats "already exists" as success), so an
/// unchanged token never commits again.
@MainActor
final class PushController: NSObject, ObservableObject {
    static let shared = PushController()
    static let devicesFolder = "Areas/Finance/monitor/devices"

    /// Bumped when a finance banner is tapped; RootView/FeaturesView switch to Finance.
    @Published var openFinanceTick = 0
    /// Bumped when a local To-Do reminder is tapped; RootView switches to To Do.
    @Published var openTodoTick = 0
    @Published private(set) var lastError: String?

    var serviceProvider: (() -> GitHubService?)?
    var onFinancePush: (() async -> Void)?

    private let uploadedKey = "push.uploadedToken"

    /// APNs environment follows the build: Xcode Run (Debug) → sandbox.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let settings = await center.notificationSettings()
        // The device token doesn't need permission; register always so the vault has it
        // even if Alp allows banners later in iOS Settings.
        UIApplication.shared.registerForRemoteNotifications()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func didRegister(token data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard UserDefaults.standard.string(forKey: uploadedKey) != token else { return }
        Task { await upload(token: token) }
    }

    func didFail(_ error: Error) {
        lastError = "Push registration failed: \(error.localizedDescription)"
    }

    private func upload(token: String) async {
        guard let service = serviceProvider?() else { return }   // no PAT yet — retried on next launch
        let env = Self.apnsEnvironment
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let body: [String: Any] = [
            "token": token,
            "env": env,
            "bundle": Bundle.main.bundleIdentifier ?? "com.alp.SecondBrainCapture",
            "device": UIDevice.current.model,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            try await service.putNewFile(path: "\(Self.devicesFolder)/\(env)-\(hash).json",
                                         content: data,
                                         message: "rocky's vault: push token (\(env))")
            UserDefaults.standard.set(token, forKey: uploadedKey)
            lastError = nil
        } catch {
            lastError = "Couldn't save push token: \(error.localizedDescription)"
        }
    }
}

extension PushController: UNUserNotificationCenterDelegate {
    /// Foreground: still show the banner, and refresh so the card is already there.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { Task { await self.onFinancePush?() } }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let tab = response.notification.request.content.userInfo["tab"] as? String
        await MainActor.run {
            switch tab {
            case "finance":
                self.openFinanceTick += 1
                Task { await self.onFinancePush?() }
            case "todo":
                self.openTodoTick += 1
            default:
                break
            }
        }
    }
}

/// UIKit hooks SwiftUI doesn't expose: the APNs device-token callbacks.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = PushController.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushController.shared.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushController.shared.didFail(error) }
    }
}
