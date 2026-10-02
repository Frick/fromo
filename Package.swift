// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "FromoCore", targets: ["FromoCore"]),
    .executable(name: "fromo", targets: ["FromoCLI"]),
]

var targets: [Target] = [
    .target(name: "FromoCore"),
    .executableTarget(name: "FromoCLI", dependencies: [
        "FromoCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .testTarget(name: "FromoCoreTests", dependencies: ["FromoCore"]),
]

#if os(macOS)
products.append(.executable(name: "FromoApp", targets: ["FromoApp"]))
targets.append(.executableTarget(name: "FromoApp", dependencies: ["FromoCore"]))
#endif

let package = Package(
    name: "Fromo",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: targets
)
