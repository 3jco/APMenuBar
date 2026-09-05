// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "APMenuBar",
            path: "Sources/APMenuBar",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "RoamSpike",
            path: "Sources/RoamSpike",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("CoreWLAN")]
        ),
    ]
)
