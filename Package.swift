// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kokoko",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KokokoCore", targets: ["KokokoCore"]),
        .library(name: "KokokoMIDI", targets: ["KokokoMIDI"]),
        .library(name: "KokokoAudio", targets: ["KokokoAudio"]),
    ],
    targets: [
        .target(name: "KokokoCore"),
        .target(name: "KokokoMIDI", dependencies: ["KokokoCore"]),
        .target(name: "KokokoAudio", dependencies: ["KokokoCore"]),
        .target(name: "VirtualEP", dependencies: ["KokokoCore", "KokokoMIDI"]),
        .executableTarget(name: "vep", dependencies: ["VirtualEP"]),
                .executableTarget(name: "kokoko-probe", dependencies: ["KokokoMIDI"]),
        .executableTarget(name: "kokoko-e2e",
                          dependencies: ["KokokoCore", "KokokoMIDI", "KokokoAudio", "VirtualEP"]),
        .executableTarget(name: "KokokoCoreChecks", dependencies: ["KokokoCore", "KokokoMIDI", "KokokoAudio"]),
        // macOS smoke-run of the real UI without Xcode: swift run kokoko-mac
        .executableTarget(name: "kokoko-mac",
                          dependencies: ["KokokoCore", "KokokoMIDI", "KokokoAudio"],
                          path: "App/Sources"),
    ]
)
