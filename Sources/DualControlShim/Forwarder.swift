#if canImport(Darwin)
    import DualControlCore
    import DualControlIPC
    import Foundation

    /// Sends every tool call to the app and turns any failure into a tool error. Knows nothing about MCP.
    struct Forwarder: Sendable {
        var client: IPCClient

        func call(tool: String, arguments: [String: JSONValue]) async -> ToolResult {
            let request = IPCRequest(id: UUID().uuidString, tool: tool, arguments: arguments)
            do {
                let response = try await client.send(request)
                if let result = response.result { return result }
                let message = response.failure?.message ?? "no result"
                return ToolResult(text: "Dual Control rejected the call: \(message)", isError: true)
            } catch IPCError.appNotRunning {
                return .appNotRunning
            } catch is CancellationError {
                return ToolResult(text: "The call was cancelled.", isError: true)
            } catch {
                log("call to \(tool) failed: \(error)")
                return ToolResult(text: "Could not reach the Dual Control app: \(error)", isError: true)
            }
        }
    }

    /// Logs go to stderr; stdout carries MCP only.
    func log(_ message: String) {
        FileHandle.standardError.write(Data("dualcontrol-shim: \(message)\n".utf8))
    }
#endif
