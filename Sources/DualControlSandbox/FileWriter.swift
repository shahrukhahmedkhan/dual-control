#if canImport(Darwin)
    import Darwin
    import DualControlCore
    import Foundation

    extension Sandbox {
        /// Starts one step of a `write_file` or `apply_patch` launch: `FileWrite.readArgv` or `FileWrite.writeArgv`
        /// for the launch's own path, as the agent in CHANGING, in the file's folder, which must still resolve to
        /// itself inside the session folder.
        public func startFileStep(_ launch: Launch, _ command: [String]) throws -> RunningCommand {
            let request = launch.request
            guard request.capability == .file, let file = FileRequest(argv: request.argv),
                file.describes(request.payload), launch.scope == scope,
                RealPath.resolve(request.cwd) == request.cwd, scope.contains(request.cwd),
                command.count >= 5, command[4] == file.path,
                command.prefix(4) == ["/bin/sh", "-c", FileWrite.readScript, "read_file"]
                    || command.prefix(4) == ["/bin/sh", "-c", FileWrite.writeScript, "write_file"]
            else { throw SandboxError.outsideScope }
            let full = try argv(command, kind: .changing, environment: AgentEnvironment.commandVariables(scope: scope))
            return try RunningCommand(
                argv: full,
                cwd: request.cwd,
                timeout: FileWrite.timeoutSeconds,
                killer: killer()
            )
        }

        /// The whole `write_file` or `apply_patch`, step after step, waiting for each. The app runs the steps itself
        /// so Stop can kill each one and is checked between them.
        public func writeFile(_ launch: Launch) -> Result<FileWritten, FileWrite.Problem> {
            func run(_ command: [String]) -> Result<CommandOutcome, FileWrite.Problem> {
                Result { try startFileStep(launch, command).wait() }
                    .mapError { FileWrite.Problem(description: "\($0)") }
            }
            let path = FileRequest(argv: launch.request.argv)?.path ?? ""
            var current: [UInt8]?
            if FileWrite.needsCurrent(launch.request) {
                switch run(FileWrite.readArgv(path: path)).flatMap(FileWrite.readResult) {
                case .failure(let problem): return .failure(problem)
                case .success(let bytes): current = bytes
                }
            }
            return FileWrite.contentToWrite(launch.request, current: current).flatMap { plan in
                run(FileWrite.writeArgv(path: path, expected: plan.expected, content: plan.content))
                    .flatMap { FileWrite.writeResult($0, content: plan.content) }
            }
        }
    }
#endif
