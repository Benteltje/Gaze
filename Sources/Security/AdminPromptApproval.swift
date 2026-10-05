import AppKit
import ApplicationServices
import Security
import os

/// Fills macOS's own administrator password prompts ("Allow administrator access…")
/// after the same face check as browser approval: an enrolled face held for two
/// seconds, anti-spoof, and a movement.
///
/// Off by default, and only ever acts on a prompt that:
/// - belongs to Apple's signed SecurityAgent,
/// - asks for this account (the user name field is this user),
/// - is not one of Gaze's own prompts (Gaze never approves itself),
/// - has a title in Apple's exact wording and no other text (an app can add its
///   own words to the prompt, so those refuse it),
/// - uniquely names a running app Gaze may handle: no scripts, no shells or
///   scripting tools, exactly one running app with that name, Apple-used names
///   must be Apple-signed from /System/ or /Applications/, others Apple-signed
///   or notarized from /Applications or ~/Applications, and the requester must be
///   the app that was in front,
/// - fills via the accessibility value first and presses the prompt's default
///   button, falling back to keystrokes only with focus re-checked before each
///   event, so the password can never land in another app.
/// Touch ID prompts get their Use Password button pressed only after the nod, and
/// the revealed window must be the one that was checked and pass every check again.
/// Each prompt gets one try; a prompt that stays open afterwards is left to the user.
@MainActor
final class AdminPromptApproval {
	private let store: FaceEnrollmentStore
	private let lockout: LockoutManager
	private var timer: Timer?
	private var busy = false
	private let check: FaceApprovalCheck
	/// Prompts already tried, so a refused or cancelled one is never retried.
	private var handled: [AXUIElement] = []
	private static let logger = Logger(subsystem: "com.gazeunlock.Gaze", category: "AdminPrompt")
	private static let agentIdentifier = "com.apple.SecurityAgent"
	/// Most recent frontmost app that is not SecurityAgent, for the requester check.
	private static var frontmostBundleID: String?
	private static var frontmostPID: pid_t?
	private var activationObserver: NSObjectProtocol?
	private static let appleRequesterNames: Set<String> = ["installer", "system settings",
		"system preferences", "software update", "disk utility", "finder",
		"migration assistant", "directory utility", "keychain access"]

	init(store: FaceEnrollmentStore, lockout: LockoutManager, check: FaceApprovalCheck) {
		self.store = store
		self.lockout = lockout
		self.check = check
	}

	func start() {
		if activationObserver == nil {
			activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
				forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
				guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
				guard app.bundleIdentifier != Self.agentIdentifier else { return }
				Self.frontmostBundleID = app.bundleIdentifier
				Self.frontmostPID = app.processIdentifier
			}
		}
		guard timer == nil else { return }
		let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.poll() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	private var enabled: Bool {
		Preferences.shared.approveAdminPrompts && !Preferences.shared.isPaused
			&& PasswordReplaySafety.isEnabled
			&& UnlockExecutionPolicy.current.permitsBrowserApproval(passwordReplayEnabled: PasswordReplaySafety.isEnabled)
	}

	/// Declined checks in a row; two of them pause handling so a flood of prompts
	/// cannot wear the user down into nodding.
	private var declines = 0
	private var pausedUntil: ContinuousClock.Instant?

	// MARK: - Finding a prompt

	private struct Prompt {
		let pid: pid_t
		let window: AXUIElement
		let field: AXUIElement?
		let usePasswordButton: AXUIElement?
		/// Static texts in window order; the first is the title line.
		let texts: [String]
		/// Every other title, description and value the window exposes.
		let otherStrings: [String]
	}

	/// The requester as checked, for the consent panel.
	private struct Requester {
		let title: AdminPromptRules.Title
		let path: String
		let signer: String
	}

	private func poll() {
		if let pausedUntil {
			guard ContinuousClock.now >= pausedUntil else { return }
			self.pausedUntil = nil
		}
		guard enabled, !busy, AXIsProcessTrusted(), AutofillConsoleSession.current() != nil else {
			if !busy { handled.removeAll() }
			return
		}
		let agents = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentIdentifier)
		guard !agents.isEmpty else {
			handled.removeAll()
			return
		}
		for agent in agents {
			guard let prompt = Self.prompts(in: agent.processIdentifier).first(where: { candidate in
				!handled.contains(where: { CFEqual($0, candidate.window) })
			}) else { continue }
			handled.append(prompt.window)
			guard Self.isAppleSecurityAgent(pid: prompt.pid) else {
				Self.logger.error("A password prompt came from a process that isn't Apple's SecurityAgent; ignoring it.")
				continue
			}
			// Re-read on every prompt rather than trusting the cached setting alone.
			guard Preferences.adminPromptApprovalIsStored() else {
				Self.logger.notice("Not handling the admin prompt: the setting is not confirmed in the keychain.")
				continue
			}
			let requester: Requester
			switch Self.evaluate(prompt) {
			case .refused(let reason):
				Self.logger.notice("Not handling the admin prompt: \(reason, privacy: .public)")
				continue
			case .allowed(let checked):
				requester = checked
			}
			busy = true
			Task { [weak self] in
				await self?.approve(prompt, requester: requester)
				self?.busy = false
			}
			return
		}
	}

	private static func prompts(in pid: pid_t) -> [Prompt] {
		let app = AXUIElementCreateApplication(pid)
		var found: [Prompt] = []
		for window in elements(app, kAXWindowsAttribute) {
			var secure: AXUIElement?
			var usePasswordButton: AXUIElement?
			var userName: String?
			var texts: [String] = []
			var others: [String] = []
			walk(window, depth: 0) { element in
				let role = string(element, kAXRoleAttribute)
				for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
					if let text = string(element, attribute), !text.isEmpty { others.append(text) }
				}
				switch role {
				case kAXTextFieldRole:
					if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { secure = element }
					else if userName == nil { userName = string(element, kAXValueAttribute) }
				case kAXStaticTextRole:
					if let text = string(element, kAXValueAttribute) { texts.append(text) }
				case kAXButtonRole:
					if usePasswordButton == nil {
						let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
						if title == "Use Password…" || title == "Use Password..." { usePasswordButton = element }
					}
				default: break
				}
			}
			// Gaze's own Touch ID prompts guard its settings; approving them with the
			// face they protect would make them pointless.
			guard !(texts + others).contains(where: { $0.contains("Gaze") }) else { continue }
			if let secure {
				guard let userName,
					userName == NSUserName() || userName == NSFullUserName() else { continue }
				found.append(Prompt(pid: pid, window: window, field: secure, usePasswordButton: usePasswordButton,
					texts: texts, otherStrings: others))
				continue
			}
			// Touch ID layout: no password field yet, so no user name to check; the
			// name check runs again once the button reveals the password field.
			guard let button = usePasswordButton else { continue }
			found.append(Prompt(pid: pid, window: window, field: nil, usePasswordButton: button,
				texts: texts, otherStrings: others))
		}
		return found
	}

	/// Apple-signed and identified as SecurityAgent: a lookalike window from any other
	/// process never gets the password.
	private static func isAppleSecurityAgent(pid: pid_t) -> Bool {
		var code: SecCode?
		let attributes = [kSecGuestAttributePid: pid] as CFDictionary
		guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
		var requirement: SecRequirement?
		guard SecRequirementCreateWithString("anchor apple and identifier \"\(agentIdentifier)\"" as CFString, [], &requirement) == errSecSuccess,
			let requirement else { return false }
		return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
	}

	private enum Evaluation {
		case allowed(Requester)
		case refused(String)
	}

	/// Whether Gaze may handle this prompt. Never filled: prompts whose title is
	/// not in Apple's wording or that carry any other text (an app can add its own
	/// through the authorization environment), scripts, shells and scripting tools,
	/// anything not currently running as a signed app, unsigned or tampered apps,
	/// duplicated names, Apple names claimed from outside /System/ or /Applications/
	/// or without an Apple signature, other apps outside an Applications folder, and
	/// requesters that were not the app in front.
	private static func evaluate(_ prompt: Prompt) -> Evaluation {
		let title: AdminPromptRules.Title
		switch AdminPromptRules.evaluate(staticTexts: prompt.texts, otherStrings: prompt.otherStrings) {
		case .refused(let reason): return .refused(reason)
		case .allowed(let parsed): title = parsed
		}
		let name = title.name
		let risky: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh",
			"osascript", "python", "python3", "perl", "ruby", "node", "swift",
			"sudo", "security", "curl", "launchctl",
			// Signed, but they run whatever code they're handed, so a signature says
			// nothing about what is asking.
			"terminal", "iterm2", "iterm", "warp", "ghostty", "script editor", "automator",
			"shortcuts", "shortcuts events"]
		if risky.contains(name.lowercased()) { return .refused("scripting tools are never approved") }
		let matches = NSWorkspace.shared.runningApplications.filter { $0.localizedName == name }
		guard !matches.isEmpty else { return .refused("no running app matches the requester") }
		guard matches.count == 1, let match = matches.first else {
			return .refused("more than one running app matches the requester")
		}
		guard let bundleURL = match.bundleURL else { return .refused("the requesting app has no bundle") }
		let url = bundleURL.resolvingSymlinksInPath().standardizedFileURL
		let path = url.path
		let signer: String
		if appleRequesterNames.contains(name.lowercased()) {
			guard isAppleSigned(bundleURL: url) else { return .refused("the requesting app is not Apple-signed") }
			guard path.hasPrefix("/System/") || path.hasPrefix("/Applications/") else {
				return .refused("the requesting app is outside the system and applications folders")
			}
			signer = "Apple"
		} else {
			guard isSignedByAppleOrNotarized(bundleURL: url) else { return .refused("the requesting app is not signed and notarized") }
			if let reason = AdminPromptRules.pathRefusal(path, home: realHome) { return .refused(reason) }
			guard isOnApplicationsVolume(url) else {
				return .refused("the requesting app is on a different volume from its Applications folder")
			}
			signer = isAppleSigned(bundleURL: url) ? "Apple" : (signerName(bundleURL: url) ?? "Unknown developer")
		}
		guard let frontPID = frontmostPID,
			match.processIdentifier == frontPID,
			match.bundleIdentifier == frontmostBundleID else {
			return .refused("requester was not the app in front")
		}
		return .allowed(Requester(title: title, path: path, signer: signer))
	}

	private static var realHome: String {
		FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
	}

	/// A disk image mounted inside an Applications folder sits on its own volume;
	/// the app must share the volume of the folder it claims to be in.
	private static func isOnApplicationsVolume(_ url: URL) -> Bool {
		let home = realHome
		let folder = url.path.hasPrefix("/Applications/")
			? URL(fileURLWithPath: "/Applications")
			: URL(fileURLWithPath: home).appendingPathComponent("Applications")
		guard let appVolume = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
			let folderVolume = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
		return appVolume.isEqual(folderVolume)
	}

	/// Apple-signed only: no notarized third-party passes for Apple-used names.
	private static func isAppleSigned(bundleURL: URL) -> Bool {
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
		var requirement: SecRequirement?
		guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
			requirement != nil else { return false }
		return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
	}

	/// Apple-signed or Developer ID notarized; ad-hoc, unsigned, un-notarized or
	/// tampered fails. No fallback: if the requirement cannot be built, nothing passes.
	private static func isSignedByAppleOrNotarized(bundleURL: URL) -> Bool {
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
		let strict = "(anchor apple) or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and notarized)"
		var requirement: SecRequirement?
		guard SecRequirementCreateWithString(strict as CFString, [], &requirement) == errSecSuccess,
			let requirement else { return false }
		return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
	}

	/// The developer as the signature names it, e.g. "Example Inc (ABCDE12345)".
	private static func signerName(bundleURL: URL) -> String? {
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
		var info: CFDictionary?
		guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
			let dict = info as? [String: Any] else { return nil }
		let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
		if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
			let leaf = certificates.first,
			let summary = SecCertificateCopySubjectSummary(leaf) as String? {
			let prefix = "Developer ID Application: "
			let name = summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary
			if let team, !name.contains(team) { return "\(name) (\(team))" }
			return name
		}
		return team
	}

	// MARK: - Approving

	private func approve(_ prompt: Prompt, requester: Requester) async {
		guard (try? PasswordVault.containsPassword()) == true, !PasswordVault.isStale else { return }
		let name = requester.title.name
		let subject = "\(name) \(requester.title.action)"
		let details = FaceApprovalCheck.Details(name: name, action: requester.title.action, rows: [
			(label: "Location", value: AdminPromptRules.abbreviated(requester.path, home: Self.realHome)),
			(label: "Signed by", value: requester.signer),
		])
		let outcome = await check.run(subject: subject, details: details,
			isStillWanted: { [weak self] in self?.enabled == true && Self.isOpen(prompt.window) },
			onApproved: { [weak self] in
				guard let self else { return false }
				return await self.confirmAndFill(prompt, requester: requester)
			})
		Self.logger.notice("Admin prompt check ended: \(String(describing: outcome), privacy: .public)")
		switch outcome {
		case .approved:
			declines = 0
		case .cancelled, .failed:
			declines += 1
			if declines >= 2 {
				declines = 0
				pausedUntil = ContinuousClock.now.advanced(by: .seconds(300))
				Self.logger.notice("Two admin prompts in a row were declined; not handling admin prompts for 5 minutes.")
			}
		case .unavailable:
			break
		}
	}

	/// Runs only after the face and nod passed. Reveals the password field if the
	/// prompt is the Touch ID layout, then fills only if the window is the same one
	/// that was checked and still passes every check.
	private func confirmAndFill(_ prompt: Prompt, requester: Requester) async -> Bool {
		var current = Self.prompts(in: prompt.pid).first { CFEqual($0.window, prompt.window) }
		if current?.field == nil {
			guard let button = current?.usePasswordButton ?? prompt.usePasswordButton else { return false }
			AXUIElementPerformAction(button, kAXPressAction as CFString)
			current = nil
			for _ in 0..<20 {
				try? await Task.sleep(for: .milliseconds(100))
				if let next = Self.prompts(in: prompt.pid).first(where: { CFEqual($0.window, prompt.window) }),
					next.field != nil {
					current = next
					break
				}
			}
		}
		guard let current, current.field != nil, CFEqual(current.window, prompt.window) else {
			Self.logger.notice("The checked prompt did not show its password field; not filling.")
			return false
		}
		if !handled.contains(where: { CFEqual($0, current.window) }) { handled.append(current.window) }
		guard enabled, Preferences.adminPromptApprovalIsStored(), Self.isAppleSecurityAgent(pid: current.pid) else {
			return false
		}
		switch Self.evaluate(current) {
		case .refused(let reason):
			Self.logger.notice("The prompt changed after the face check (\(reason, privacy: .public)); not filling.")
			return false
		case .allowed(let again):
			guard again.title == requester.title, again.path == requester.path, again.signer == requester.signer else {
				Self.logger.notice("The prompt's requester changed after the face check; not filling.")
				return false
			}
		}
		return fill(current)
	}

	/// Sets the password via the accessibility value and presses the prompt's
	/// default button, falling back to keystrokes only if setting the value
	/// fails, with the system-wide focused element re-checked before each
	/// posted event so the password can never land in another app.
	@discardableResult
	private func fill(_ prompt: Prompt) -> Bool {
		guard let field = prompt.field else { return false }
		let systemWide = AXUIElementCreateSystemWide()
		var focused: CFTypeRef?
		guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
			let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
			CFEqual(focused as! AXUIElement, field) else {
			Self.logger.notice("The prompt's password field lost focus; not typing.")
			return false
		}
		do {
			guard let password = try PasswordVault.password() else { return false }
			if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, password as CFString) == .success {
				var readable = false
				var nonEmpty = false
				var countValue: CFTypeRef?
				if AXUIElementCopyAttributeValue(field, "AXNumberOfCharacters" as CFString, &countValue) == .success {
					readable = true
					if let n = countValue as? Int { nonEmpty = n > 0 }
					else if let n = countValue as? NSNumber { nonEmpty = n.intValue > 0 }
				} else {
					var value: CFTypeRef?
					if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
						let s = value as? String {
						readable = true
						nonEmpty = !s.isEmpty
					}
				}
				guard !readable || nonEmpty else {
					Self.logger.notice("The prompt's password field did not take the value; not submitting.")
					return false
				}
				if let button = Self.defaultButton(in: prompt.window) {
					AXUIElementPerformAction(button, kAXPressAction as CFString)
				} else {
					Self.logger.notice("The prompt has no default button; leaving it for the user to submit.")
				}
				Self.logger.notice("Admin prompt filled after a face check.")
				return true
			}
			let events = try Keystrokes.clearFieldEvents() + Keystrokes.passwordEvents(password)
			guard CGPreflightPostEventAccess() else { return false }
			for event in events {
				var current: CFTypeRef?
				guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &current) == .success,
					let current, CFGetTypeID(current) == AXUIElementGetTypeID(),
					CFEqual(current as! AXUIElement, field) else {
					Self.logger.notice("The prompt's password field lost focus while typing; stopped.")
					return false
				}
				event.post(tap: .cghidEventTap)
			}
			Self.logger.notice("Admin prompt filled after a face check.")
			return true
		} catch {
			Self.logger.error("Could not fill the admin prompt: \(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	/// The prompt's submit button: the window's default button, a button marked
	/// as the default, or a known submit title.
	private static func defaultButton(in window: AXUIElement) -> AXUIElement? {
		var def: CFTypeRef?
		if AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString, &def) == .success,
			let def, CFGetTypeID(def) == AXUIElementGetTypeID() {
			return def as! AXUIElement
		}
		let titles: Set<String> = ["Allow Access", "OK", "Unlock", "Install Software", "Modify Configuration"]
		var titled: AXUIElement?
		var marked: AXUIElement?
		walk(window, depth: 0) { element in
			guard string(element, kAXRoleAttribute) == kAXButtonRole else { return }
			if marked == nil {
				if string(element, kAXSubroleAttribute) == "AXDefaultButton" {
					marked = element
				} else {
					var flag: CFTypeRef?
					if AXUIElementCopyAttributeValue(element, "AXDefaultButton" as CFString, &flag) == .success {
						if let b = flag as? Bool, b { marked = element }
						else if let n = flag as? NSNumber, n.boolValue { marked = element }
					}
				}
			}
			if titled == nil, let title = string(element, kAXTitleAttribute), titles.contains(title) {
				titled = element
			}
		}
		return marked ?? titled
	}

	// MARK: - Accessibility helpers

	/// Whether the window still exists: a closed window's element stops answering.
	private static func isOpen(_ window: AXUIElement) -> Bool {
		var value: CFTypeRef?
		return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value) == .success
	}

	private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
		return value as? [AXUIElement] ?? []
	}

	private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
		return value as? String
	}

	private static func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Void) {
		guard depth < 12 else { return }
		visit(element)
		for child in elements(element, kAXChildrenAttribute) { walk(child, depth: depth + 1, visit) }
	}
}
