// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipboardXKit", targets: ["ClipboardXKit"]),
        .executable(name: "cx-import", targets: ["cx-import"]),
        .executable(name: "ClipboardX", targets: ["ClipboardXApp"]),
    ],
    targets: [
        .target(name: "ClipboardXKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "cx-import", dependencies: ["ClipboardXKit"]),
        .executableTarget(name: "ClipboardXApp", dependencies: ["ClipboardXKit"]),
        .testTarget(name: "ClipboardXKitTests", dependencies: ["ClipboardXKit"]),
    ]
)
