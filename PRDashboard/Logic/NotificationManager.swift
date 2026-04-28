import Foundation
import UserNotifications
import AppKit

final class NotificationManager: NSObject, ObservableObject {
    @Published private(set) var isAuthorized = false
    var openURL: (@MainActor (URL) -> Void)?

    private let notificationCenter = UNUserNotificationCenter.current()
    private var mutedPRIds: Set<Int> = []

    private let mutedPRsKey = "muted_pr_ids"
    private var lastNotificationTime: [Int: Date] = [:]
    private let notificationThrottleInterval: TimeInterval = 600  // 10 minutes

    override init() {
        super.init()
        notificationCenter.delegate = self
        loadMutedPRs()
    }

    func requestPermission() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    func notify(pr: PullRequest, newUnresolvedCount: Int) {
        guard isAuthorized else { return }
        guard !mutedPRIds.contains(pr.id) else { return }

        // Throttle notifications
        if let lastTime = lastNotificationTime[pr.id],
           Date().timeIntervalSince(lastTime) < notificationThrottleInterval {
            return
        }

        lastNotificationTime[pr.id] = Date()

        let content = UNMutableNotificationContent()
        content.title = "\(pr.repoFullName) #\(pr.number)"
        if newUnresolvedCount == 1 {
            content.body = String(localized: "1 new unresolved comment on \"\(pr.title)\"")
        } else {
            content.body = String(localized: "\(newUnresolvedCount) new unresolved comments on \"\(pr.title)\"")
        }
        content.sound = .default
        content.userInfo = ["pr_url": pr.url.absoluteString, "pr_id": pr.id]
        content.categoryIdentifier = "PR_NOTIFICATION"

        let request = UNNotificationRequest(
            identifier: "pr-\(pr.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    func notifyCIStatusChange(pr: PullRequest, newStatus: CIStatus) {
        guard isAuthorized else { return }
        guard !mutedPRIds.contains(pr.id) else { return }

        // Throttle notifications
        if let lastTime = lastNotificationTime[pr.id],
           Date().timeIntervalSince(lastTime) < notificationThrottleInterval {
            return
        }

        lastNotificationTime[pr.id] = Date()

        let content = UNMutableNotificationContent()
        content.title = "\(pr.repoFullName) #\(pr.number)"

        switch newStatus {
        case .success:
            content.body = String(localized: "All CI checks passed on \"\(pr.title)\"")
        case .failure:
            content.body = String(localized: "CI checks failed on \"\(pr.title)\"")
        default:
            return  // Don't notify for pending/expected
        }

        content.sound = .default
        content.userInfo = ["pr_url": pr.url.absoluteString, "pr_id": pr.id]
        content.categoryIdentifier = "PR_NOTIFICATION"

        let request = UNNotificationRequest(
            identifier: "ci-\(pr.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to schedule CI notification: \(error.localizedDescription)")
            }
        }
    }

    func mutePR(_ prId: Int) {
        mutedPRIds.insert(prId)
        saveMutedPRs()
    }

    func unmutePR(_ prId: Int) {
        mutedPRIds.remove(prId)
        saveMutedPRs()
    }

    func isPRMuted(_ prId: Int) -> Bool {
        mutedPRIds.contains(prId)
    }

    // MARK: - Private

    private func loadMutedPRs() {
        if let ids = UserDefaults.standard.array(forKey: mutedPRsKey) as? [Int] {
            mutedPRIds = Set(ids)
        }
    }

    private func saveMutedPRs() {
        UserDefaults.standard.set(Array(mutedPRIds), forKey: mutedPRsKey)
    }

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_PR",
            title: String(localized: "Open PR"),
            options: .foreground
        )

        let muteAction = UNNotificationAction(
            identifier: "MUTE_PR",
            title: String(localized: "Mute Notifications"),
            options: .destructive
        )

        let category = UNNotificationCategory(
            identifier: "PR_NOTIFICATION",
            actions: [openAction, muteAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([category])
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case "OPEN_PR", UNNotificationDefaultActionIdentifier:
            if let urlString = userInfo["pr_url"] as? String,
               let url = URL(string: urlString) {
                if let openURL {
                    Task { @MainActor in
                        openURL(url)
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }

        case "MUTE_PR":
            if let prId = userInfo["pr_id"] as? Int {
                mutePR(prId)
            }

        default:
            break
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
