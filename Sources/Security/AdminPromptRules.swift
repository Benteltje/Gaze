import Foundation

/// The pure checks behind `AdminPromptApproval`: reading who is asking from a
/// SecurityAgent prompt and where that app may live. Kept free of AppKit and
/// accessibility so the rules can be tested on their own.
///
/// Everything here fails closed. An app can add its own words to the prompt
/// through `kAuthorizationEnvironmentPrompt`, so the requester is read only from
/// the title line in Apple's exact wording, and any other text refuses the prompt.
enum AdminPromptRules {
	struct Title: Equatable {
		/// The requesting app's name, quotes stripped.
		let name: String
		/// What the title says it wants, e.g. "wants to make changes" or
		/// "is trying to install new software".
		let action: String
	}

	/// Apple's fixed wording below the title and on the buttons. Anything else in
	/// the window refuses the prompt; a localized prompt is refused too.
	static let knownFixedTexts: Set<String> = [
		"Enter your password to allow this.",
		"Touch ID or enter your password to allow this.",
		"User Name:", "Password:",
		"Cancel", "OK", "Allow", "Allow Access", "Unlock", "Modify Settings",
		"Install Software", "Modify Configuration", "Use Password…", "Use Password...",
	]

	private static let quotePairs: [(Character, Character)] = [("“", "”"), ("\"", "\""), ("‘", "’"), ("'", "'")]
	private static let quoteCharacters: Set<Character> = ["“", "”", "\"", "‘", "’", "'", "«", "»", "„", "‟"]

	/// Parses the title line against Apple's two patterns:
	/// `<name> wants to make changes.` and `<name> is trying to <action>.`
	static func parseTitle(_ line: String) -> Title? {
		guard !line.contains(where: \.isNewline), line.hasSuffix(".") else { return nil }
		let body = String(line.dropLast())
		let rawName: String
		let action: String
		if body.hasSuffix(" wants to make changes") {
			rawName = String(body.dropLast(" wants to make changes".count))
			action = "wants to make changes"
		} else if let range = body.range(of: " is trying to ") {
			rawName = String(body[..<range.lowerBound])
			let clause = String(body[range.upperBound...])
			guard !clause.isEmpty, !clause.contains(where: { quoteCharacters.contains($0) }),
				!clause.contains(" is trying to ") else { return nil }
			action = "is trying to " + clause
		} else {
			return nil
		}
		guard let name = unquoted(rawName) else { return nil }
		return Title(name: name, action: action)
	}

	/// The name with one matching pair of surrounding quotes removed. Nil when it
	/// is empty, padded, or still holds a quote character.
	private static func unquoted(_ raw: String) -> String? {
		var name = raw
		for (open, close) in quotePairs where name.count >= 2 && name.first == open && name.last == close {
			name = String(name.dropFirst().dropLast())
			break
		}
		guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
			!name.contains(where: { quoteCharacters.contains($0) || $0.isNewline }) else { return nil }
		return name
	}

	/// Every quoted run in the text, for checking that nothing in the window names
	/// a different app from the title.
	static func quotedNames(in text: String) -> [String] {
		var names: [String] = []
		for (open, close) in [("“", "”"), ("\"", "\"")] as [(Character, Character)] {
			var rest = Substring(text)
			while let start = rest.firstIndex(of: open) {
				let after = rest[rest.index(after: start)...]
				guard let end = after.firstIndex(of: close) else { break }
				names.append(String(after[..<end]))
				rest = after[after.index(after: end)...]
			}
		}
		return names
	}

	enum Evaluation: Equatable {
		case allowed(Title)
		case refused(String)
	}

	/// Reads the requester from the prompt's static texts, in window order, and
	/// every other string the window exposes (titles, descriptions).
	static func evaluate(staticTexts: [String], otherStrings: [String]) -> Evaluation {
		let texts = staticTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
		guard let first = texts.first else { return .refused("the prompt has no title") }
		guard let title = parseTitle(first) else { return .refused("the title is not in Apple's wording") }
		if title.name.range(of: "script", options: .caseInsensitive) != nil
			|| title.action.range(of: "script", options: .caseInsensitive) != nil {
			return .refused("scripts are never approved")
		}
		for text in texts.dropFirst() where !knownFixedTexts.contains(text) {
			return .refused("the prompt carries text Gaze does not recognise")
		}
		for string in texts + otherStrings {
			for quoted in quotedNames(in: string) where quoted != title.name {
				return .refused("the prompt names more than one app")
			}
		}
		return .allowed(title)
	}

	/// Where a non-Apple requester may live: inside /Applications or
	/// ~/Applications, never a download, temporary, mounted or translocated copy.
	/// `path` must already have its symlinks resolved.
	static func pathRefusal(_ path: String, home: String) -> String? {
		let components = path.split(separator: "/", omittingEmptySubsequences: false)
		guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
			return "the requesting app's path is not plain"
		}
		let homeApps = home.hasSuffix("/") ? home + "Applications/" : home + "/Applications/"
		guard path.hasPrefix("/Applications/") || (!home.isEmpty && path.hasPrefix(homeApps)) else {
			return "the requesting app is not in an Applications folder"
		}
		let lower = path.lowercased()
		for marker in ["/apptranslocation/", "/volumes/", "/private/", "/tmp/", "/downloads/", ".dmg/", ".sparsebundle/", ".sparseimage/"]
			where lower.contains(marker) {
			return "the requesting app runs from a temporary, mounted or downloaded copy"
		}
		return nil
	}

	/// The path with the home folder shown as ~.
	static func abbreviated(_ path: String, home: String) -> String {
		guard !home.isEmpty else { return path }
		if path == home { return "~" }
		let prefix = home.hasSuffix("/") ? home : home + "/"
		return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
	}
}
