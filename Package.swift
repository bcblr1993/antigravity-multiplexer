// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AntigravityMultiplexer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AntigravityMultiplexer", targets: ["AntigravityMultiplexer"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "AntigravityMultiplexer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
