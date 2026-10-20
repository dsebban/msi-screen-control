// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MSIScreenControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "msi-screen", targets: ["msi-screen"]),
        .executable(name: "MSIScreenMenu", targets: ["MSIScreenMenu"])
    ],
    targets: [
        .target(name: "MSIScreenCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "msi-screen", dependencies: ["MSIScreenCore"]),
        .executableTarget(name: "MSIScreenMenu", dependencies: ["MSIScreenCore"]),
        .testTarget(name: "MSIScreenCoreTests", dependencies: ["MSIScreenCore"]),
        .testTarget(name: "MSIScreenMenuTests", dependencies: ["MSIScreenMenu"])
    ]
)
