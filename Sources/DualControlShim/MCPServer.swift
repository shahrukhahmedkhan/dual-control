// All MCP SDK code lives in this file, so the SDK can be swapped without touching the rest.
#if canImport(MCP)
    import DualControlCore
    import Foundation
    import MCP

    enum MCPFrontEnd {
        /// An MCP server whose tool list and instructions come from Core and whose calls go to `forwarder`.
        static func makeServer(forwarder: Forwarder) async -> Server {
            let server = Server(
                name: "dual-control",
                version: DualControlCore.version,
                title: "Dual Control",
                instructions: ServerInstructions.text,
                capabilities: .init(tools: .init(listChanged: false))
            )
            let tools = ToolCatalogue.all.map(tool)
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
            await server.withMethodHandler(CallTool.self) { parameters in
                let arguments: [String: JSONValue] = (parameters.arguments ?? [:]).compactMapValues { convert($0) }
                let result = await forwarder.call(tool: parameters.name, arguments: arguments)
                // An abandoned call gets no response (MCP cancellation); the forwarder has already hung up.
                try Task.checkCancellation()
                return .init(content: [.text(text: result.text, annotations: nil, _meta: nil)], isError: result.isError)
            }
            return server
        }

        /// Serves MCP on stdin/stdout until the client disconnects.
        static func run(forwarder: Forwarder) async throws {
            let server = await makeServer(forwarder: forwarder)
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        }

        static func tool(_ spec: ToolSpec) -> Tool {
            Tool(
                name: spec.name,
                title: spec.title,
                description: spec.description,
                inputSchema: convert(spec.inputSchema) ?? .object([:]),
                annotations: .init(
                    title: spec.title,
                    readOnlyHint: spec.isReadOnly,
                    destructiveHint: !spec.isReadOnly,
                    openWorldHint: false
                )
            )
        }

        /// Converts between the SDK's JSON type and Core's through JSON, so neither depends on the other.
        static func convert<From: Encodable, To: Decodable>(_ value: From) -> To? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(To.self, from: data)
        }
    }
#endif
