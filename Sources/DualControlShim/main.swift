// dualcontrol-shim: launched by the MCP client (Claude Desktop) over stdio. Lists tools from Core and forwards every
// call to the running app over the local socket. No other behaviour.
#if canImport(MCP) && canImport(Darwin)
    import DualControlIPC
    import Foundation

    do {
        try await MCPFrontEnd.run(forwarder: Forwarder(client: IPCClient()))
    } catch {
        log("stopped: \(error)")
        exit(1)
    }
#else
    import Foundation

    FileHandle.standardError.write(Data("dualcontrol-shim runs on macOS only\n".utf8))
    exit(1)
#endif
