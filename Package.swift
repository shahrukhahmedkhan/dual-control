// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DualControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DualControlCore", targets: ["DualControlCore"]),
        .library(name: "DualControlIPC", targets: ["DualControlIPC"]),
        .library(name: "DualControlStore", targets: ["DualControlStore"]),
        .library(name: "DualControlSandbox", targets: ["DualControlSandbox"]),
        .library(name: "DualControlSerial", targets: ["DualControlSerial"]),
        .library(name: "DualControlNetwork", targets: ["DualControlNetwork"]),
        .library(name: "DualControlTerminal", targets: ["DualControlTerminal"]),
        .executable(name: "dualcontrol-shim", targets: ["DualControlShim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0"),
        // Used only in Sources/DualControlShim/MCPServer.swift, so the SDK can be swapped.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // The terminal view. The same exact version as the app's reference in App/DualControl.xcodeproj.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1"),
    ],
    targets: [
        // Pure logic, no I/O. Must build and test on Linux.
        .target(
            name: "DualControlCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        // Unix socket between shim and app. macOS only; compiles to nothing elsewhere.
        .target(
            name: "DualControlIPC",
            dependencies: ["DualControlCore"]
        ),
        // The app's audit files and settings. macOS only; compiles to nothing elsewhere.
        .target(
            name: "DualControlStore",
            dependencies: ["DualControlCore", "DualControlIPC"]
        ),
        // The ceiling on disk and the kernel sandbox for agent processes. macOS only; compiles to nothing elsewhere.
        .target(
            name: "DualControlSandbox",
            dependencies: ["DualControlCore", .target(name: "CMembership", condition: .when(platforms: [.macOS]))]
        ),
        // Serial ports, opened by the app itself (termios, IOKit). macOS only; compiles to nothing elsewhere.
        .target(
            name: "DualControlSerial",
            dependencies: ["DualControlCore"],
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]
        ),
        // The gatekeeper proxy agent processes reach the network through. macOS only; compiles to nothing elsewhere.
        .target(
            name: "DualControlNetwork",
            dependencies: ["DualControlCore"]
        ),
        // The owner's view of the agent's terminal, hardened against agent output. macOS only; compiles to nothing
        // elsewhere.
        .target(
            name: "DualControlTerminal",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS]))]
        ),
        // <membership.h> for DualControlSandbox.
        .systemLibrary(name: "CMembership"),
        .executableTarget(
            name: "DualControlShim",
            dependencies: [
                "DualControlCore",
                "DualControlIPC",
                .product(name: "MCP", package: "swift-sdk", condition: .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "DualControlCoreTests",
            dependencies: ["DualControlCore"]
        ),
        .testTarget(
            name: "DualControlIPCTests",
            dependencies: ["DualControlCore", "DualControlIPC"]
        ),
        .testTarget(
            name: "DualControlStoreTests",
            dependencies: ["DualControlCore", "DualControlStore"]
        ),
        .testTarget(
            name: "DualControlSandboxTests",
            dependencies: ["DualControlCore", "DualControlSandbox", "DualControlNetwork"]
        ),
        .testTarget(
            name: "DualControlNetworkTests",
            dependencies: ["DualControlCore", "DualControlNetwork"]
        ),
        .testTarget(
            name: "DualControlSerialTests",
            dependencies: ["DualControlCore", "DualControlSerial"]
        ),
        .testTarget(
            name: "DualControlTerminalTests",
            dependencies: [
                "DualControlTerminal",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "DualControlShimTests",
            dependencies: [
                "DualControlCore",
                "DualControlIPC",
                "DualControlShim",
                .product(name: "MCP", package: "swift-sdk", condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)
