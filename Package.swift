// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DevHub", path: "Sources/DevHub", linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
