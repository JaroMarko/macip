// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "macip",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "macip", targets: ["macip"])],
    targets: [
        .target(name: "MacIPCore"),
        .executableTarget(name: "macip", dependencies: ["MacIPCore"]),
        .executableTarget(name: "MacIPChecks", dependencies: ["MacIPCore"], path: "Tests/MacIPCoreTests")
    ]
)
