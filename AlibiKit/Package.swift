// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AlibiKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlibiKit", targets: ["AlibiKit"]),
        .executable(name: "alibi-probe", targets: ["alibi-probe"])
    ],
    targets: [
        .target(
            name: "AlibiKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "alibi-probe", dependencies: ["AlibiKit"]),
        .testTarget(name: "AlibiKitTests", dependencies: ["AlibiKit"])
    ]
)
