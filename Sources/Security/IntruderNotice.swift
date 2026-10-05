import AppKit
import UserNotifications

/// Tells the owner that someone else tried to unlock the Mac, once they're back.
///
/// The notice waits for the next unlock on purpose. Shown at once it would appear on
/// the lock screen, to the person who just failed, and tell them they were seen and
/// photographed: news for the owner, not for them.
@MainActor
final class IntruderNotice {
	static let shared = IntruderNotice()

	private var count = 0
	private var firstAt: Date?
	private var latestPhoto: URL?
	private var observer: NSObjectProtocol?

	private init() {
		observer = DistributedNotificationCenter.default().addObserver(
			forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
		) { _ in
			MainActor.assumeIsolated { IntruderNotice.shared.screenUnlocked() }
		}
	}

	func noteAttempt(at date: Date, photo: URL?) {
		count += 1
		if firstAt == nil { firstAt = date }
		if let photo { latestPhoto = photo }
	}

	private func screenUnlocked() {
		guard count > 0, let firstAt else { return }
		let tries = count, photo = latestPhoto
		count = 0
		self.firstAt = nil
		latestPhoto = nil
		guard Bundle.main.bundleURL.pathExtension == "app" else { return }
		// The photo is written in the background; give it a moment to land.
		DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
			Self.post(tries: tries, firstAt: firstAt, photo: photo)
		}
	}

	private static func post(tries: Int, firstAt: Date, photo: URL?) {
		let content = UNMutableNotificationContent()
		content.title = "Someone tried to unlock your Mac"
		let time = firstAt.formatted(date: .omitted, time: .shortened)
		content.body = tries == 1
			? "1 try at \(time) while you were away. See it in Gaze."
			: "\(tries) tries while you were away, starting at \(time). See them in Gaze."
		// UNNotificationAttachment moves its file, so it gets a copy.
		if let photo, FileManager.default.fileExists(atPath: photo.path) {
			let copy = FileManager.default.temporaryDirectory
				.appendingPathComponent("gaze-intruder-\(UUID().uuidString).jpg")
			if (try? FileManager.default.copyItem(at: photo, to: copy)) != nil,
				let attachment = try? UNNotificationAttachment(identifier: "photo", url: copy) {
				content.attachments = [attachment]
			}
		}
		let request = UNNotificationRequest(identifier: "gaze-intruder", content: content, trigger: nil)
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
			guard granted else { return }
			center.add(request)
		}
	}
}
