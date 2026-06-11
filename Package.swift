// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NASMounter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "NASMounter",
            path: "Sources/NASMounter",
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
