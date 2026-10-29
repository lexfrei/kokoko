// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kokoko",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KokokoCore", targets: ["KokokoCore"])
    ],
    targets: [
        .target(name: "KokokoCore"),
        .executableTarget(name: "KokokoCoreChecks", dependencies: ["KokokoCore"]),
    ]
)
