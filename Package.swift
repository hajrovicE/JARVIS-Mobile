// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "JarvisCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "JarvisCore", targets: ["JarvisCore"])],
    targets: [
        .target(name: "JarvisCore"),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"])
    ]
)
