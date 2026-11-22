/// The admin steps the owner runs once to create the agent user (ISO-001). The app only shows these commands, with
/// the owner's name filled in at runtime; it never runs them or keeps a password.
public struct SetupGuide: Sendable, Equatable {
    /// One step: what it does and the command to paste into Terminal.
    public struct Step: Sendable, Equatable, Identifiable {
        /// Stable identifier.
        public let id: String
        /// Short title.
        public let title: String
        /// What the step does and why.
        public let explanation: String
        /// The exact command.
        public let command: String
    }

    /// The prefix that runs a command as the agent; sudoers allows only sandbox-exec after it.
    public static let runAsAgent = ["/usr/bin/sudo", "-n", "-u", AgentEnvironment.user, "--"]
    /// Where the sudoers rule is installed.
    public static let sudoersPath = "/etc/sudoers.d/dualcontrol"
    /// What the agent may do in the Developer folder. It can never change permissions or owners.
    public static let aclRights =
        "list,add_file,search,add_subdirectory,delete_child,read,write,append,execute,delete,"
        + "readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"

    /// The owner's short user name.
    public let ownerUser: String
    /// The owner's home folder.
    public let ownerHome: String

    /// A guide for the owner, or `nil` if the name is not a plain short user name (it goes into shell commands
    /// and sudoers) or the home is not an absolute, canonical path.
    public init?(ownerUser: String, ownerHome: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard !ownerUser.isEmpty, ownerUser.count <= 32, ownerUser.allSatisfy(allowed.contains),
            !ownerUser.hasPrefix("-"), !["root", AgentEnvironment.user, "all"].contains(ownerUser),
            SessionScope.developerCeiling(ownerHome: ownerHome) != nil
        else { return nil }
        self.ownerUser = ownerUser
        self.ownerHome = ownerHome.count > 1 && ownerHome.hasSuffix("/") ? String(ownerHome.dropLast()) : ownerHome
    }

    /// The owner's Developer folder (the ceiling, not resolved).
    public var developer: String { ownerHome + "/" + SessionScope.ceilingFolderName }
    var workArea: String { developer + "/" + SessionScope.workAreaFolderName }
    /// The Dual Control repo folder, which the agent is denied by ACL as well as by the sandbox.
    var protectedRepo: String { developer + "/" + SessionScope.protectedFolderName }

    /// The one sudoers rule: the owner may run sandbox-exec as the agent, nothing else, and the agent gets no rights.
    public var sudoersLine: String {
        "\(ownerUser) ALL=(\(AgentEnvironment.user)) NOPASSWD: /usr/bin/sandbox-exec"
    }

    /// The steps, in order.
    public var steps: [Step] {
        let agent = AgentEnvironment.user
        return [
            Step(
                id: "user",
                title: "Create the agent user",
                explanation: "A hidden standard user (not an admin) with a random password nobody needs to know. "
                    + "Its home is inside your Developer folder.",
                command: "sudo /usr/sbin/sysadminctl -addUser \(agent) -fullName 'Claude Agent' "
                    + #"-password "$(/usr/bin/openssl rand -base64 32)" "#
                    + "-home \(Self.quoted(workArea + "/agent-home")) -shell /bin/zsh"
                    + " && sudo /usr/bin/dscl . -create /Users/\(agent) IsHidden 1"
            ),
            Step(
                id: "folders",
                title: "Create the agent's work area",
                explanation: "Its HOME and TMPDIR. You own them; the agent gets access through the next step.",
                command: "/bin/mkdir -p \(Self.quoted(workArea + "/agent-home")) \(Self.quoted(workArea + "/tmp"))"
            ),
            Step(
                id: "acl",
                title: "Share the Developer folder with the agent",
                explanation: "Lets the agent read and write in your Developer folder, including new files. The "
                    + "sandbox narrows that to the session folder; the agent can never change permissions. The "
                    + "Dual Control folder gets a deny entry for the agent, which wins over the allow. On a big "
                    + "folder tree this can take a while.",
                command: "/bin/chmod -R +a \(Self.quoted("\(agent) allow \(Self.aclRights)")) \(Self.quoted(developer))"
                    + " && { [ ! -d \(Self.quoted(protectedRepo)) ] || /bin/chmod -R +a "
                    + "\(Self.quoted("\(agent) deny \(Self.aclRights)")) \(Self.quoted(protectedRepo)); }"
            ),
            Step(
                id: "sudoers",
                title: "Let Dual Control start sandboxed processes as the agent",
                explanation: "One sudoers rule: you may run sandbox-exec as \(agent), without a password, and "
                    + "nothing else. It is checked with visudo before it is installed.",
                command: #"f="$(/usr/bin/mktemp)" && printf '%s\n' "# + Self.quoted(sudoersLine) + #" > "$f""#
                    + #" && sudo /usr/sbin/visudo -cf "$f""#
                    + #" && sudo /usr/bin/install -m 0440 -o root -g wheel "$f" \#(Self.sudoersPath)"#
                    + #"; rm -f "$f"; sudo /usr/sbin/visudo -c"#
            ),
        ]
    }

    /// `text` in single quotes for zsh/sh.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
