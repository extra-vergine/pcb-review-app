// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "KiCadKit", targets: ["KiCadKit"]),
    .executable(name: "kicad-inspect", targets: ["kicad-inspect"]),
]
var targets: [Target] = [
    .target(name: "KiCadKit", resources: [.copy("Profiles")]),
    .executableTarget(name: "kicad-inspect", dependencies: ["KiCadKit"]),
    .testTarget(
        name: "KiCadKitTests",
        dependencies: ["KiCadKit"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// The SwiftUI app only builds on macOS. Run it with `swift run PCBReview [board.kicad_pcb]`
// or open Package.swift in Xcode and run the PCBReview scheme.
products.append(.executable(name: "PCBReview", targets: ["PCBReview"]))
targets.append(.executableTarget(name: "PCBReview", dependencies: ["KiCadKit"]))
#endif

let package = Package(
    name: "PCBReview",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
