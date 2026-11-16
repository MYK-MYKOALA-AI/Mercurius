// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CursusCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CursusCore", targets: ["CursusCore"]),
        .executable(name: "CursusVox", targets: ["CursusVox"])
    ],
    targets: [
        .target(name: "CursusCore"),
        .target(name: "CursusPlatform", linkerSettings: [.linkedFramework("ApplicationServices")]),
        .executableTarget(name: "CursusVox", dependencies: ["CursusCore", "CursusPlatform"]),
        .testTarget(name: "CursusCoreTests", dependencies: ["CursusCore"]),
        .testTarget(name: "CursusNativeTests", dependencies: ["CursusVox"])
    ],
    swiftLanguageModes: [.v6]
)
