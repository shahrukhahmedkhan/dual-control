import Foundation

/// What a forwarded tool call asks for.
public enum ToolRoute: Sendable, Equatable {
    /// `status`: answered from the engine's state.
    case status
    /// A call the policy engine decides.
    case action(tool: String, ActionRequest)
    /// `request_takeover`: moves the baton; the reason is shown to the owner.
    case takeover(reason: String)
    /// `run_command` (or `git_clone`) with `background: true`: decided like a command, but answered at once with a
    /// job id.
    case job(tool: String, ActionRequest)
    /// `job_status`: a job's state and the last `lines` of its output.
    case jobStatus(id: String, lines: Int)
    /// `job_cancel`.
    case jobCancel(id: String)
    /// `activity`: the newest `limit` feed entries.
    case activity(limit: Int)
    /// `serial_close`.
    case serialClose(session: String)
    /// A known tool that has no implementation yet.
    case notImplemented(tool: String)
    /// A known tool whose arguments do not match its schema.
    case invalid(tool: String, message: String)
    /// A name that is not in the catalogue.
    case unknown(tool: String)
}

/// Turns a forwarded tool call into a route. Stateless; arguments are checked strictly against the tool's schema.
public enum ToolRouter {
    /// The route for `request`.
    public static func route(_ request: IPCRequest) -> ToolRoute {
        guard let tool = ToolCatalogue.named(request.tool) else { return .unknown(tool: request.tool) }
        let arguments = request.arguments
        switch tool.name {
        case ToolCatalogue.status.name:
            guard arguments.isEmpty else { return .invalid(tool: tool.name, message: "status takes no arguments") }
            return .status
        case ToolCatalogue.runCommand.name:
            return runCommand(arguments)
        case ToolCatalogue.gitClone.name, ToolCatalogue.gitInit.name:
            return git(tool.name, arguments)
        case ToolCatalogue.espIdfInstall.name:
            return espIdfInstall(arguments)
        case ToolCatalogue.terminalSend.name:
            guard Set(arguments.keys).isSubset(of: ["text", "tab"]), case .string(let text)? = arguments["text"],
                let tab = tab(arguments["tab"])
            else {
                return .invalid(tool: tool.name, message: "expected a string `text` and maybe `tab` agent or second")
            }
            // The pane starts in the session folder; rules never apply to terminal text.
            var request = ActionRequest(capability: .terminal, argv: [text], cwd: "", projectID: "")
            request.tab = tab
            return .action(tool: tool.name, request)
        case ToolCatalogue.gitCommit.name:
            guard Set(arguments.keys).isSubset(of: ["repository", "message", "branch"]),
                case .string(let repository)? = arguments["repository"],
                case .string(let message)? = arguments["message"]
            else {
                return .invalid(tool: tool.name, message: "expected strings `repository`, `message` and maybe `branch`")
            }
            if let problem = GitCommit.messageProblem(message) { return .invalid(tool: tool.name, message: problem) }
            guard let folder = normalizedFolder(repository), GitSetup.folderProblem(folder) == nil else {
                return .invalid(tool: tool.name, message: "`repository` must be an absolute folder")
            }
            var branch = ""
            if let value = arguments["branch"] {
                guard case .string(let name) = value else {
                    return .invalid(tool: tool.name, message: "`branch` must be a string")
                }
                if let problem = GitReview.branchProblem(name, defaultBranch: nil) {
                    return .invalid(tool: tool.name, message: problem)
                }
                branch = name
            }
            // The supervisor adds the identity (`GitCommit.argv`); message and branch wait in argv until then.
            return .action(
                tool: tool.name,
                ActionRequest(
                    capability: .command,
                    argv: [message, branch],
                    cwd: folder,
                    projectID: folder,
                    timeoutSeconds: GitCommit.timeoutSeconds
                )
            )
        case ToolCatalogue.gitSync.name:
            guard Set(arguments.keys).isSubset(of: ["repository", "action", "branch"]),
                case .string(let repository)? = arguments["repository"],
                case .string(let name)? = arguments["action"]
            else {
                return .invalid(tool: tool.name, message: "expected strings `repository`, `action` and maybe `branch`")
            }
            var branch: String?
            if let value = arguments["branch"] {
                guard case .string(let named) = value else {
                    return .invalid(tool: tool.name, message: "`branch` must be a string")
                }
                branch = named
            }
            let action: GitSync.Action
            switch GitSync.parse(name, branch: branch) {
            case .failure(let problem): return .invalid(tool: tool.name, message: problem.description)
            case .success(let parsed): action = parsed
            }
            guard let folder = normalizedFolder(repository), GitSetup.folderProblem(folder) == nil else {
                return .invalid(tool: tool.name, message: "`repository` must be an absolute folder")
            }
            // The supervisor adds the identity (`GitSync.argv`); action and branch wait in argv until then.
            return .action(
                tool: tool.name,
                ActionRequest(
                    capability: .command,
                    argv: [action.name, action.branch],
                    cwd: folder,
                    projectID: folder,
                    timeoutSeconds: GitSync.timeoutSeconds
                )
            )
        case ToolCatalogue.claudeCodeStart.name:
            guard arguments.isEmpty else { return .invalid(tool: tool.name, message: "it takes no arguments") }
            // The supervisor types the fixed line for the session's newest install (`ClaudeCode.launchLine`).
            return .action(tool: tool.name, ActionRequest(capability: .terminal, argv: [], cwd: "", projectID: ""))
        case ToolCatalogue.terminalRead.name:
            var lines = 100
            if let value = arguments["lines"] {
                guard case .int(let count) = value, (1...2000).contains(count) else {
                    return .invalid(tool: tool.name, message: "`lines` must be an integer from 1 to 2000")
                }
                lines = count
            }
            guard Set(arguments.keys).isSubset(of: ["lines", "tab"]), let tab = tab(arguments["tab"]) else {
                return .invalid(tool: tool.name, message: "expected an integer `lines` and maybe `tab` agent or second")
            }
            var request = ActionRequest(capability: .terminalRead, argv: [String(lines)], cwd: "", projectID: "")
            request.tab = tab
            return .action(tool: tool.name, request)
        case ToolCatalogue.jobStatus.name:
            guard Set(arguments.keys).isSubset(of: ["id", "lines"]), case .string(let id)? = arguments["id"] else {
                return .invalid(tool: tool.name, message: "expected a string `id` and an optional integer `lines`")
            }
            guard let lines = integer(arguments["lines"], default: 50, in: 1...2000) else {
                return .invalid(tool: tool.name, message: "`lines` must be an integer from 1 to 2000")
            }
            return .jobStatus(id: id, lines: lines)
        case ToolCatalogue.jobCancel.name:
            guard Set(arguments.keys) == ["id"], case .string(let id)? = arguments["id"] else {
                return .invalid(tool: tool.name, message: "expected only a string `id`")
            }
            return .jobCancel(id: id)
        case ToolCatalogue.activity.name:
            guard Set(arguments.keys).isSubset(of: ["limit"]),
                let limit = integer(arguments["limit"], default: 20, in: 1...100)
            else {
                return .invalid(tool: tool.name, message: "`limit` must be an integer from 1 to 100")
            }
            return .activity(limit: limit)
        case ToolCatalogue.requestTakeover.name:
            guard Set(arguments.keys) == ["reason"], case .string(let reason)? = arguments["reason"], !reason.isEmpty
            else {
                return .invalid(tool: tool.name, message: "expected only a non-empty string `reason`")
            }
            return .takeover(reason: reason)
        case ToolCatalogue.serialList.name:
            guard arguments.isEmpty else { return .invalid(tool: tool.name, message: "serial_list takes no arguments") }
            return serial(tool.name, .list)
        case ToolCatalogue.serialOpen.name:
            return serialOpen(arguments)
        case ToolCatalogue.serialRead.name:
            return serialRead(arguments)
        case ToolCatalogue.serialWrite.name:
            return serialWrite(arguments)
        case ToolCatalogue.serialReset.name:
            guard Set(arguments.keys) == ["session", "mode"], case .string(let session)? = arguments["session"],
                case .string(let name)? = arguments["mode"], let mode = SerialResetMode(rawValue: name)
            else {
                return .invalid(tool: tool.name, message: "expected a string `session` and `mode` run or bootloader")
            }
            return serial(tool.name, .reset(session: session, mode))
        case ToolCatalogue.serialClose.name:
            guard Set(arguments.keys) == ["session"], case .string(let session)? = arguments["session"] else {
                return .invalid(tool: tool.name, message: "expected only a string `session`")
            }
            return .serialClose(session: session)
        case ToolCatalogue.netAllowRequest.name:
            return netAllowRequest(arguments)
        case ToolCatalogue.writeFile.name:
            return writeFile(arguments)
        case ToolCatalogue.applyPatch.name:
            return applyPatch(arguments)
        default:
            return .notImplemented(tool: tool.name)
        }
    }

    /// `net_allow_request`: a checked LAN endpoint and the reason, as a `.network` request the owner decides.
    static func netAllowRequest(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.netAllowRequest.name
        guard Set(arguments.keys).isSubset(of: ["host", "port", "protocol", "why"]),
            case .string(let host)? = arguments["host"], case .int(let port)? = arguments["port"],
            case .string(let why)? = arguments["why"], !why.isEmpty, why.count <= 500
        else {
            return .invalid(
                tool: name,
                message: "expected a string `host`, an integer `port`, a non-empty `why` (at most 500 characters) "
                    + "and optionally `protocol`"
            )
        }
        var transport = "tcp"
        if let value = arguments["protocol"] {
            guard case .string(let given) = value else {
                return .invalid(tool: name, message: "`protocol` must be a string")
            }
            transport = given
        }
        switch LANEndpoint.parse(host: host, port: port, transport: transport) {
        case .failure(let problem):
            return .invalid(tool: name, message: problem.description)
        case .success(let endpoint):
            return .action(
                tool: name,
                ActionRequest(capability: .network, argv: endpoint.argv(why: why), cwd: "", projectID: "")
            )
        }
    }

    /// `write_file`: a checked path and the content, from `content` (UTF-8 text) or `content_base64`, exactly one.
    static func writeFile(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.writeFile.name
        guard Set(arguments.keys).isSubset(of: ["path", "content", "content_base64"]),
            case .string(let path)? = arguments["path"]
        else {
            return .invalid(tool: name, message: "expected a string `path` and `content` or `content_base64`")
        }
        if let problem = FileWrite.pathProblem(path) { return .invalid(tool: name, message: problem) }
        let content: [UInt8]
        switch (arguments["content"], arguments["content_base64"]) {
        case (.string(let text)?, nil):
            content = Array(text.utf8)
        case (nil, .string(let encoded)?):
            guard let data = Data(base64Encoded: encoded) else {
                return .invalid(tool: name, message: "`content_base64` is not valid base64")
            }
            content = Array(data)
        default:
            return .invalid(tool: name, message: "give exactly one of the strings `content` and `content_base64`")
        }
        guard content.count <= FileWrite.maxBytes else {
            return .invalid(tool: name, message: "the content is larger than \(FileWrite.maxBytes) bytes")
        }
        return .action(tool: name, FileWrite.writeRequest(path: path, content: content))
    }

    /// `apply_patch`: a checked path and a unified diff of that one file, read before anyone is asked.
    static func applyPatch(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.applyPatch.name
        guard Set(arguments.keys) == ["path", "patch"], case .string(let path)? = arguments["path"],
            case .string(let text)? = arguments["patch"]
        else {
            return .invalid(tool: name, message: "expected only the strings `path` and `patch`")
        }
        if let problem = FileWrite.pathProblem(path) { return .invalid(tool: name, message: problem) }
        guard text.utf8.count <= FileWrite.maxBytes else {
            return .invalid(tool: name, message: "the patch is larger than \(FileWrite.maxBytes) bytes")
        }
        switch UnifiedPatch.parse(text) {
        case .failure(let problem): return .invalid(tool: name, message: problem.description)
        case .success(let patch):
            return .action(tool: name, FileWrite.patchRequest(path: path, text: text, patch: patch))
        }
    }

    /// The supervisor fills in the working directory (the session folder) and the device.
    static func serial(_ tool: String, _ operation: SerialOperation) -> ToolRoute {
        .action(tool: tool, ActionRequest(capability: .serial, argv: operation.argv, cwd: "", projectID: ""))
    }

    static func serialOpen(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.serialOpen.name
        guard Set(arguments.keys).isSubset(of: ["port", "baud", "data_bits", "parity", "stop_bits", "flow"]) else {
            return .invalid(tool: name, message: "unexpected argument")
        }
        guard case .string(let port)? = arguments["port"], SerialPorts.isListed(port) else {
            return .invalid(tool: name, message: "`port` must be a /dev/cu.* path from serial_list")
        }
        guard case .int(let baud)? = arguments["baud"] else {
            return .invalid(tool: name, message: "`baud` must be an integer")
        }
        guard let dataBits = integer(arguments["data_bits"], default: 8, in: 5...8),
            let stopBits = integer(arguments["stop_bits"], default: 1, in: 1...2)
        else {
            return .invalid(tool: name, message: "`data_bits` must be 5 to 8 and `stop_bits` 1 or 2")
        }
        var parity = SerialSettings.Parity.none
        if let value = arguments["parity"] {
            guard case .string(let text) = value, let parsed = SerialSettings.Parity(rawValue: text) else {
                return .invalid(tool: name, message: "`parity` must be none, even or odd")
            }
            parity = parsed
        }
        var flow = SerialSettings.Flow.none
        if let value = arguments["flow"] {
            guard case .string(let text) = value, let parsed = SerialSettings.Flow(rawValue: text) else {
                return .invalid(tool: name, message: "`flow` must be none or rts_cts")
            }
            flow = parsed
        }
        guard
            let settings = SerialSettings(
                baud: baud,
                dataBits: dataBits,
                parity: parity,
                stopBits: stopBits,
                flow: flow
            )
        else {
            let range = SerialLimits.baudRange
            return .invalid(tool: name, message: "`baud` must be from \(range.lowerBound) to \(range.upperBound)")
        }
        return serial(name, .open(port: port, settings))
    }

    static func serialRead(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.serialRead.name
        guard Set(arguments.keys).isSubset(of: ["session", "max_bytes", "wait_ms", "hex"]),
            case .string(let session)? = arguments["session"]
        else {
            return .invalid(tool: name, message: "expected a string `session`, `max_bytes`, `wait_ms` and `hex`")
        }
        guard
            let maxBytes = integer(
                arguments["max_bytes"],
                default: SerialLimits.defaultReadBytes,
                in: 1...SerialLimits.maxReadBytes
            )
        else {
            return .invalid(
                tool: name,
                message: "`max_bytes` must be an integer from 1 to \(SerialLimits.maxReadBytes)"
            )
        }
        guard
            let wait = integer(
                arguments["wait_ms"],
                default: SerialLimits.defaultWaitMilliseconds,
                in: 0...SerialLimits.maxWaitMilliseconds
            )
        else {
            return .invalid(
                tool: name,
                message: "`wait_ms` must be an integer from 0 to \(SerialLimits.maxWaitMilliseconds)"
            )
        }
        var hex = false
        if let value = arguments["hex"] {
            guard case .bool(let flag) = value else { return .invalid(tool: name, message: "`hex` must be a boolean") }
            hex = flag
        }
        return serial(name, .read(session: session, maxBytes: maxBytes, waitMilliseconds: wait, hex: hex))
    }

    static func serialWrite(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.serialWrite.name
        let keys = Set(arguments.keys)
        guard keys == ["session", "text"] || keys == ["session", "hex"],
            case .string(let session)? = arguments["session"]
        else {
            return .invalid(tool: name, message: "expected a string `session` and either `text` or `hex`")
        }
        let bytes: [UInt8]
        switch (arguments["text"], arguments["hex"]) {
        case (.string(let text)?, nil):
            bytes = Array(text.utf8)
        case (nil, .string(let hex)?):
            guard let decoded = SerialText.bytes(hex: hex) else {
                return .invalid(tool: name, message: "`hex` must be pairs of hex digits")
            }
            bytes = decoded
        default:
            return .invalid(tool: name, message: "`text` and `hex` must be strings")
        }
        guard (1...SerialLimits.maxWriteBytes).contains(bytes.count) else {
            return .invalid(tool: name, message: "write 1 to \(SerialLimits.maxWriteBytes) bytes per call")
        }
        return serial(name, .write(session: session, bytes: bytes))
    }

    static func runCommand(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.runCommand.name
        guard Set(arguments.keys).isSubset(of: ["argv", "cwd", "timeout_seconds", "background"]) else {
            return .invalid(tool: name, message: "unexpected argument")
        }
        guard case .array(let values)? = arguments["argv"], !values.isEmpty else {
            return .invalid(tool: name, message: "`argv` must be a non-empty array of strings")
        }
        var argv: [String] = []
        for value in values {
            guard case .string(let argument) = value else {
                return .invalid(tool: name, message: "`argv` must be a non-empty array of strings")
            }
            argv.append(argument)
        }
        guard case .string(let cwd)? = arguments["cwd"], let folder = normalizedFolder(cwd) else {
            return .invalid(tool: name, message: "`cwd` must be an absolute path")
        }
        var timeoutSeconds: Int?
        if let timeout = arguments["timeout_seconds"] {
            guard case .int(let seconds) = timeout, (1...CommandLimits.maxTimeoutSeconds).contains(seconds) else {
                return .invalid(tool: name, message: "`timeout_seconds` must be an integer from 1 to 3600")
            }
            timeoutSeconds = seconds
        }
        var background = false
        if let value = arguments["background"] {
            guard case .bool(let flag) = value else {
                return .invalid(tool: name, message: "`background` must be a boolean")
            }
            background = flag
        }
        // The working directory stands in for the project; rules match it as a folder.
        let request = ActionRequest(
            capability: .command,
            argv: argv,
            cwd: cwd,
            projectID: folder,
            timeoutSeconds: timeoutSeconds
        )
        return background ? .job(tool: name, request) : .action(tool: name, request)
    }

    /// `esp_idf_install`: the fixed script with a checked version and targets, always as a job. The working directory
    /// is the session folder, set when it is decided.
    static func espIdfInstall(_ arguments: [String: JSONValue]) -> ToolRoute {
        let name = ToolCatalogue.espIdfInstall.name
        guard Set(arguments.keys).isSubset(of: ["version", "targets"]) else {
            return .invalid(tool: name, message: "unexpected argument")
        }
        guard case .string(let version)? = arguments["version"] else {
            return .invalid(tool: name, message: "`version` must be a string")
        }
        if let problem = ESPIDFInstall.versionProblem(version) { return .invalid(tool: name, message: problem) }
        guard case .array(let values)? = arguments["targets"] else {
            return .invalid(tool: name, message: "`targets` must be an array of strings")
        }
        var targets: [String] = []
        for case .string(let target) in values { targets.append(target) }
        guard targets.count == values.count else {
            return .invalid(tool: name, message: "`targets` must be an array of strings")
        }
        if let problem = ESPIDFInstall.targetsProblem(targets) { return .invalid(tool: name, message: problem) }
        let request = ActionRequest(
            capability: .command,
            argv: ESPIDFInstall.argv(version: version, targets: targets),
            cwd: "",
            projectID: "",
            timeoutSeconds: ESPIDFInstall.timeoutSeconds
        )
        return .job(tool: name, request)
    }

    /// `git_clone` or `git_init`: a fixed command line run in the new repository's parent folder (`GitSetup`).
    static func git(_ name: String, _ arguments: [String: JSONValue]) -> ToolRoute {
        let isClone = name == ToolCatalogue.gitClone.name
        let allowed: Set<String> = isClone ? ["url", "folder", "background"] : ["folder"]
        guard Set(arguments.keys).isSubset(of: allowed) else {
            return .invalid(tool: name, message: "unexpected argument")
        }
        guard case .string(let folder)? = arguments["folder"] else {
            return .invalid(tool: name, message: "`folder` must be a string")
        }
        if let problem = GitSetup.folderProblem(folder) { return .invalid(tool: name, message: problem) }
        var background = false
        if let value = arguments["background"] {
            guard case .bool(let flag) = value else {
                return .invalid(tool: name, message: "`background` must be a boolean")
            }
            background = flag
        }
        let parent = SandboxProfile.parent(of: folder)
        let argv: [String]
        if isClone {
            guard case .string(let url)? = arguments["url"] else {
                return .invalid(tool: name, message: "`url` must be a string")
            }
            if let problem = GitSetup.urlProblem(url) { return .invalid(tool: name, message: problem) }
            argv = GitSetup.cloneArgv(url: url, folder: folder)
        } else {
            argv = GitSetup.initArgv(folder: folder)
        }
        let request = ActionRequest(
            capability: .command,
            argv: argv,
            cwd: parent,
            projectID: parent,
            timeoutSeconds: isClone ? GitSetup.timeoutSeconds : GitSetup.initTimeoutSeconds
        )
        return background ? .job(tool: name, request) : .action(tool: name, request)
    }

    /// The tab a terminal tool names: `nil` (the agent tab) if absent or "agent", `.second` for "second"; `.none` if
    /// it is anything else.
    static func tab(_ value: JSONValue?) -> TerminalTab?? {
        guard let value else { return .some(nil) }
        guard case .string(let name) = value, let tab = TerminalTab(rawValue: name) else { return .none }
        return .some(tab == .agent ? nil : tab)
    }

    /// `value` if it is an integer in `range`, `fallback` if it is absent, otherwise `nil`.
    static func integer(_ value: JSONValue?, default fallback: Int, in range: ClosedRange<Int>) -> Int? {
        guard let value else { return fallback }
        guard case .int(let number) = value, range.contains(number) else { return nil }
        return number
    }

    /// `path` with `.`, `..` and repeated slashes resolved lexically, or `nil` if it is not absolute.
    static func normalizedFolder(_ path: String) -> String? {
        guard !path.contains("\0"), let parts = AllowRule.components(path) else { return nil }
        return "/" + parts.joined(separator: "/")
    }
}
