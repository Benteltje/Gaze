import Foundation
import UserNotifications

/// Tells the user, once, that the saved password stopped working. Settings says the
/// same, but nobody opens Settings to find out why the lock screen went quiet.
enum StalePasswordNotice {
	static func post() {
		guard Bundle.main.bundleURL.pathExtension == "app" else { return }
		let content = UNMutableNotificationContent()
		content.title = "Your Mac password changed"
		content.body = "Gaze can’t unlock until you save the new one. Open Gaze Settings, then choose Change next to Account password."
		let request = UNNotificationRequest(identifier: "gaze-stale-password", content: content, trigger: nil)
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.alert]) { granted, _ in
			guard granted else { return }
			center.add(request)
		}
	}
}
