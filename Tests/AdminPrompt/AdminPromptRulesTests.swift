import Foundation

private enum TestError: Error { case failed(String) }

@main
enum AdminPromptRulesTests {
	static var checks = 0
	static func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
		guard condition() else { throw TestError.failed(name) }
		checks += 1
		print("PASS \(name)")
	}

	static func allowed(_ texts: [String], _ others: [String] = []) -> AdminPromptRules.Title? {
		if case .allowed(let title) = AdminPromptRules.evaluate(staticTexts: texts, otherStrings: others) { return title }
		return nil
	}

	static func main() throws {
		try titleTests()
		try refusalTests()
		try pathTests()
		print("\(checks) checks passed")
	}

	static func titleTests() throws {
		try expect(AdminPromptRules.parseTitle("Installer wants to make changes.")
			== .init(name: "Installer", action: "wants to make changes"), "plain wants title")
		try expect(AdminPromptRules.parseTitle("“System Settings” wants to make changes.")?.name == "System Settings",
			"curly quoted name")
		try expect(AdminPromptRules.parseTitle("\"Foo App\" wants to make changes.")?.name == "Foo App", "straight quoted name")
		try expect(AdminPromptRules.parseTitle("Installer is trying to install new software.")
			== .init(name: "Installer", action: "is trying to install new software"), "is trying to title")
		try expect(AdminPromptRules.parseTitle("Installer wants to make changes") == nil, "missing full stop")
		try expect(AdminPromptRules.parseTitle("Installer would like to make changes.") == nil, "other wording")
		try expect(AdminPromptRules.parseTitle(" wants to make changes.") == nil, "empty name")
		try expect(AdminPromptRules.parseTitle("“Installer” needs to finish setup. Evil wants to make changes.") == nil,
			"injected quote in name")
		try expect(AdminPromptRules.parseTitle("Evil is trying to “Installer” setup.") == nil, "quote in action")
	}

	static func refusalTests() throws {
		let password = "Enter your password to allow this."
		try expect(allowed(["Installer wants to make changes.", password, "User Name:", "Password:"])?.name == "Installer",
			"valid Apple prompt")
		try expect(allowed(["Foo is trying to modify settings.", "Touch ID or enter your password to allow this."])?.name == "Foo",
			"valid Touch ID prompt")
		try expect(allowed(["Evil wants to make changes.", "“Installer” needs to finish setup", password]) == nil,
			"injected quoted text refused")
		try expect(allowed(["Evil wants to make changes.", "Please approve this update.", password]) == nil,
			"extra static text refused")
		try expect(allowed(["“Installer” needs to finish setup", "Evil wants to make changes."]) == nil,
			"injected text before the title refused")
		try expect(allowed(["Evil wants to make changes.", password], ["“Installer”"]) == nil,
			"different quoted name elsewhere refused")
		try expect(allowed(["“Foo” wants to make changes.", password], ["“Foo”"])?.name == "Foo",
			"same quoted name elsewhere allowed")
		try expect(allowed(["Script Runner wants to make changes.", password]) == nil, "script requester refused")
		try expect(allowed([]) == nil, "no title refused")
	}

	static func pathTests() throws {
		let home = "/Users/owen"
		try expect(AdminPromptRules.pathRefusal("/Applications/Foo.app", home: home) == nil, "/Applications allowed")
		try expect(AdminPromptRules.pathRefusal("/Applications/Utilities/Foo.app", home: home) == nil, "subfolder allowed")
		try expect(AdminPromptRules.pathRefusal("/Users/owen/Applications/Foo.app", home: home) == nil, "~/Applications allowed")
		try expect(AdminPromptRules.pathRefusal("/Users/owen/Downloads/Foo.app", home: home) != nil, "Downloads refused")
		try expect(AdminPromptRules.pathRefusal("/tmp/Foo.app", home: home) != nil, "/tmp refused")
		try expect(AdminPromptRules.pathRefusal("/private/var/folders/x/Foo.app", home: home) != nil, "/private refused")
		try expect(AdminPromptRules.pathRefusal("/Volumes/Foo/Foo.app", home: home) != nil, "/Volumes refused")
		try expect(AdminPromptRules.pathRefusal("/Applications/Foo.dmg/Foo.app", home: home) != nil, "disk image refused")
		try expect(AdminPromptRules.pathRefusal("/Applications/../tmp/Foo.app", home: home) != nil, "dot-dot refused")
		try expect(AdminPromptRules.pathRefusal(
			"/private/var/folders/x/AppTranslocation/ABC/d/Foo.app", home: home) != nil, "translocated refused")
		try expect(AdminPromptRules.pathRefusal("/Users/other/Applications/Foo.app", home: home) != nil,
			"another user's Applications refused")
		try expect(AdminPromptRules.pathRefusal("/Users/owen/ApplicationsX/Foo.app", home: home) != nil, "lookalike folder refused")
		try expect(AdminPromptRules.abbreviated("/Users/owen/Applications/Foo.app", home: home) == "~/Applications/Foo.app",
			"home abbreviated")
		try expect(AdminPromptRules.abbreviated("/Applications/Foo.app", home: home) == "/Applications/Foo.app",
			"system path unchanged")
	}
}
