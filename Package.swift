// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "GarageCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "GarageCore", targets: ["GarageCore"])],
    targets: [.target(name: "GarageCore"), .testTarget(name: "GarageCoreTests", dependencies: ["GarageCore"])]
)
