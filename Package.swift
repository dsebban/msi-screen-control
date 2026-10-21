// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MSIScreenControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "msi-screen", targets: ["msi-screen"]),
        .executable(name: "MSIScreenMenu", targets: ["MSIScreenMenu"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "MSIScreenCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "msi-screen", dependencies: ["MSIScreenCore"]),
        .executableTarget(name: "MSIScreenMenu", dependencies: ["MSIScreenCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MSIScreenCoreTests", dependencies: ["MSIScreenCore"],
                    resources: [.process("Fixtures/device-support-cases.json"), .copy("Fixtures/AdapterFixture.swift")]),
        .testTarget(name: "MSIScreenMenuTests", dependencies: ["MSIScreenMenu"])
    ]
)
