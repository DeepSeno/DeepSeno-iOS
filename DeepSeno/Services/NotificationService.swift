import Foundation
import UserNotifications

final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()

    private var isAuthorized = false

    func requestAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[Notification] Auth error: \(error)")
            }
        }
    }

    func sendTranscriptionComplete(recordingName: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = "\"\(recordingName)\" has been transcribed"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "transcription-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Notification] Send error: \(error)")
            }
        }
    }
}
