import Testing

@testable import DualControlCore

private let guide = SetupGuide(ownerUser: "alex", ownerHome: "/Users/alex")

@Test func theStepsAreInOrder() throws {
    let steps = try #require(guide).steps
    #expect(steps.map(\.id) == ["user", "folders", "acl", "sudoers"])
    #expect(steps.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty && !$0.command.isEmpty })
}

@Test func theAgentIsAHiddenStandardUserWithItsHomeInTheWorkArea() throws {
    let command = try #require(guide?.steps.first { $0.id == "user" }).command
    #expect(command.contains("sudo /usr/sbin/sysadminctl -addUser claude-agent"))
    #expect(command.contains("-home '/Users/alex/Developer/.dual-control/agent-home'"))
    // A random password generated in the owner's shell, never shown or stored.
    #expect(command.contains(#"-password "$(/usr/bin/openssl rand -base64 32)""#))
    #expect(!command.contains("-admin"))
    #expect(command.contains("sudo /usr/bin/dscl . -create /Users/claude-agent IsHidden 1"))
}

@Test func theWorkAreaBelongsToTheOwner() throws {
    let command = try #require(guide?.steps.first { $0.id == "folders" }).command
    #expect(
        command
            == "/bin/mkdir -p '/Users/alex/Developer/.dual-control/agent-home' "
            + "'/Users/alex/Developer/.dual-control/tmp'"
    )
}

@Test func theACLInheritsAndCannotChangePermissions() throws {
    let command = try #require(guide?.steps.first { $0.id == "acl" }).command
    #expect(command.hasPrefix("/bin/chmod -R +a 'claude-agent allow "))
    #expect(command.contains("' '/Users/alex/Developer' && "))
    #expect(command.contains("file_inherit,directory_inherit"))
    #expect(!command.contains("writesecurity") && !command.contains("chown"))
    #expect(SetupGuide.aclRights.contains("delete_child"))
}

@Test func theACLDeniesTheAgentTheProtectedFolders() throws {
    let step = try #require(guide?.steps.first { $0.id == "acl" })
    // Explicit deny entries sort before allow entries, explicit or inherited, so the deny wins. The folder may
    // not exist yet; then there is nothing to deny.
    let deny = "/bin/chmod -R +a 'claude-agent deny \(SetupGuide.aclRights)' '/Users/alex/Developer/dual-control'"
    #expect(step.command.hasSuffix("&& { [ ! -d '/Users/alex/Developer/dual-control' ] || \(deny); }"))
    let allow = try #require(step.command.range(of: "allow"))
    let denied = try #require(step.command.range(of: "deny"))
    #expect(allow.lowerBound < denied.lowerBound)
    #expect(step.explanation.contains("Dual Control"))
    #expect(step.explanation.contains("a while"))
}

@Test func sudoersLetsTheOwnerRunOnlyTheSandboxAsTheAgent() throws {
    #expect(guide?.sudoersLine == "alex ALL=(claude-agent) NOPASSWD: /usr/bin/sandbox-exec")
    let command = try #require(guide?.steps.first { $0.id == "sudoers" }).command
    // Validated before it is installed, then the whole configuration again.
    #expect(command.contains(#"sudo /usr/sbin/visudo -cf "$f""#))
    #expect(command.contains(#"sudo /usr/bin/install -m 0440 -o root -g wheel "$f" /etc/sudoers.d/dualcontrol"#))
    #expect(command.hasSuffix("sudo /usr/sbin/visudo -c"))
    #expect(command.contains("'alex ALL=(claude-agent) NOPASSWD: /usr/bin/sandbox-exec'"))
    let validate = try #require(command.range(of: "visudo -cf"))
    let install = try #require(command.range(of: "/usr/bin/install"))
    #expect(validate.lowerBound < install.lowerBound)
}

@Test(arguments: ["", "root", "claude-agent", "a b", "a'b", "a;b", "$(x)", "-x", "ALL", "a\nb", "Ä"])
func oddOwnerNamesGetNoCommands(_ user: String) {
    #expect(SetupGuide(ownerUser: user, ownerHome: "/Users/x") == nil)
}

@Test(arguments: ["", "relative", "/", "/Users/x/../y", "/Users/x\0"])
func oddHomesGetNoCommands(_ home: String) {
    #expect(SetupGuide(ownerUser: "alex", ownerHome: home) == nil)
}

@Test func homesWithQuotesAreQuotedForTheShell() throws {
    let odd = try #require(SetupGuide(ownerUser: "alex", ownerHome: "/Users/al'ex x"))
    let command = try #require(odd.steps.first { $0.id == "folders" }).command
    #expect(command.hasPrefix(#"/bin/mkdir -p '/Users/al'\''ex x/Developer/.dual-control/agent-home'"#))
}

@Test func theAgentRunsCommandsThroughSudoWithoutAPrompt() {
    #expect(SetupGuide.runAsAgent == ["/usr/bin/sudo", "-n", "-u", "claude-agent", "--"])
}
