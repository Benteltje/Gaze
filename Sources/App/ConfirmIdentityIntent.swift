import AppIntents
import Foundation

/// Set by the app at launch so the Shortcuts action can reach the live check.
@MainActor
enum FaceApprovalCenter {
	static var check: FaceApprovalCheck?
}

/// Proves presence only: the person in front of the Mac showed an enrolled face
/// and nodded. The shortcut chooses the reason text, so this action must not gate
/// privileged steps such as admin access, payments, or keychain reveals.
struct ConfirmIdentityIntent: AppIntent {
	static var title: LocalizedStringResource = "Confirm It’s You"
	static var description = IntentDescription("Asks for your face and a nod, then continues the shortcut only if it’s you.")
	static var openAppWhenRun = false

	@Parameter(title: "Reason", default: "Continue this shortcut")
	var reason: String

	@MainActor static var callTimes: [Date] = []

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
		let now = Date()
		Self.callTimes = Self.callTimes.filter { now.timeIntervalSince($0) < 60 }
		guard Self.callTimes.count < 3 else { return .result(value: false) }
		Self.callTimes.append(now)
		guard let check = FaceApprovalCenter.check else { return .result(value: false) }
		let subject = "A shortcut asks: \(Self.truncated(reason))"
		let outcome = await check.run(subject: subject, isStillWanted: { true }, onApproved: { true })
		return .result(value: outcome == .approved)
	}

	private static func truncated(_ reason: String) -> String {
		let maxReason = 30
		guard reason.count > maxReason else { return reason }
		return String(reason.prefix(15)) + "…" + String(reason.suffix(14))
	}
}

struct GazeShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: ConfirmIdentityIntent(),
			phrases: ["Confirm it’s me with \(.applicationName)"],
			shortTitle: "Confirm It’s You",
			systemImageName: "faceid"
		)
	}
}
