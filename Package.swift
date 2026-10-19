// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipLine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "clipline", targets: ["ClipLine"])
    ],
    targets: [
        .executableTarget(
            name: "ClipLine",
            path: "Sources/ClipLine"
        )
    ]
)
