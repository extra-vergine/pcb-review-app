// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PCBReview",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KiCadKit", targets: ["KiCadKit"]),
        .executable(name: "kicad-inspect", targets: ["kicad-inspect"]),
    ],
    targets: [
        .target(name: "KiCadKit"),
        .executableTarget(name: "kicad-inspect", dependencies: ["KiCadKit"]),
        .testTarget(
            name: "KiCadKitTests",
            dependencies: ["KiCadKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
