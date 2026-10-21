// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AutonomousTestingAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AutonomousTestingAgentApp", targets: ["AutonomousTestingAgentApp"]),
        .executable(name: "AutonomousTestingAgent", targets: ["AutonomousTestingAgent"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AgentInfrastructure", targets: ["AgentInfrastructure"]),
        .library(name: "AgentPresentation", targets: ["AgentPresentation"]),
        .library(name: "AgentComposition", targets: ["AgentComposition"]),
        .library(name: "AgentGateway", targets: ["AgentGateway"]),
        .library(name: "AgentMCP", targets: ["AgentMCP"]),
        .executable(name: "ata-mcp", targets: ["ata-mcp"]),
        .library(name: "AgentEngine", targets: ["AgentEngine"]),
        .library(name: "CodeIntelligence", targets: ["CodeIntelligence"]),
        .library(name: "TestCaseSources", targets: ["TestCaseSources"])
    ],
    dependencies: [
        // Parser only (no macros, builder or formatter): used by CodeIntelligence for the AST index.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0")
    ],
    targets: [
        .target(
            name: "CodeIntelligence",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .target(
            name: "TestCaseSources",
            dependencies: []
        ),
        .target(
            name: "AgentCore",
            dependencies: []
        ),
        // Adapters: everything that touches the world (idb and simctl, the model APIs, files, the Keychain-free config). Depends on the core only.
        .target(
            name: "AgentInfrastructure",
            dependencies: ["AgentCore"]
        ),
        // Observable view-models for the GUI. Depends on the core only: it never sees idb, a process or a model API.
        .target(
            name: "AgentPresentation",
            dependencies: ["AgentCore"]
        ),
        // The one place that builds the real objects (adapters) and hands them to the view-models.
        .target(
            name: "AgentComposition",
            dependencies: ["AgentCore", "AgentInfrastructure", "AgentPresentation"]
        ),
        // The tool layer other agents call: one catalogue of tools, with no transport. The MCP server and the command line's `tool` mode both read it.
        .target(
            name: "AgentGateway",
            dependencies: ["AgentCore", "AgentInfrastructure", "TestCaseSources"]
        ),
        // The Model Context Protocol server side (JSON-RPC over stdio) over the gateway's tools.
        .target(
            name: "AgentMCP",
            dependencies: ["AgentCore", "AgentGateway"]
        ),
        .executableTarget(
            name: "ata-mcp",
            dependencies: ["AgentGateway", "AgentMCP"],
            path: "Sources/MCP"
        ),
        // The engine: runs test cases, the agent team and Operate tasks. A library, so the command line tool stays a thin shell.
        .target(
            name: "AgentEngine",
            dependencies: ["AgentCore", "AgentInfrastructure", "CodeIntelligence", "TestCaseSources"]
        ),
        .executableTarget(
            name: "AutonomousTestingAgent",
            dependencies: ["AgentEngine", "AgentGateway"],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "AutonomousTestingAgentApp",
            dependencies: ["AgentCore", "AgentPresentation", "AgentComposition", "TestCaseSources"],
            path: "Sources/GUI"
        ),
        .testTarget(
            name: "AutonomousTestingAgentTests",
            dependencies: ["AgentCore", "AgentInfrastructure", "AgentPresentation", "AgentComposition", "AgentEngine", "AgentGateway", "AgentMCP", "CodeIntelligence", "TestCaseSources"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
