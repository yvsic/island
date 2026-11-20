// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Island",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                // Anti-debug / anti-tamper checks run in release builds only,
                // so lldb and friends still work against a debug build.
                .define("ISLAND_RELEASE_HARDENING", .when(configuration: .release)),
            ]
        ),
    ]
)
