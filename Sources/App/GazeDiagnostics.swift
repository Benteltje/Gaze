import AppKit
import Foundation

/// One file a user can send when unlocking misbehaves: versions, the settings that
/// change how unlocking works, and the last day of Gaze's own log messages. Gaze
/// never logs passwords or photos, so neither can end up in it.
enum GazeDiagnostics {
	private static let settingKeys = [
		"unlockMovementCount", "disabledMovements", "recognitionSensitivity", "detectionDistance",
		"unlockBackend", "allowExternalCamera", "approveAdminPrompts", "walkAwayLock",
	]

	/// Writes the report to the Desktop and shows it in Finder. Runs `log show`, which
	/// takes a few seconds, so call it off the main actor.
	static func save() async throws -> URL {
		let info = Bundle.main.infoDictionary
		var lines = [
			"Gaze \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
			"macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(model())",
			"Accessibility: \(AXIsProcessTrusted() ? "on" : "off"), Input Monitoring: \(SpaceKeyMonitor.isAllowed ? "on" : "off")",
			"",
		]
		let defaults = UserDefaults.standard
		for key in settingKeys {
			let value = defaults.object(forKey: key).map { "\($0)".replacingOccurrences(of: "\n", with: " ") } ?? "default"
			lines.append("\(key): \(value)")
		}
		lines.append("")
		lines.append(try await recentLog())

		let name = "Gaze Diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
		let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		let url = desktop.appendingPathComponent(name)
		try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	private static func recentLog() async throws -> String {
		try await Task.detached(priority: .userInitiated) {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
			process.arguments = ["show", "--last", "24h", "--style", "compact",
				"--predicate", "subsystem == \"com.gazeunlock.Gaze\""]
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = pipe
			try process.run()
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			return String(decoding: data, as: UTF8.self)
		}.value
	}

	private static func model() -> String {
		var size = 0
		sysctlbyname("hw.model", nil, &size, nil, 0)
		var bytes = [CChar](repeating: 0, count: max(size, 1))
		sysctlbyname("hw.model", &bytes, &size, nil, 0)
		return String(cString: bytes)
	}
}
