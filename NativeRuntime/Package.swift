// swift-tools-version: 6.0
import PackageDescription

// Generated artifacts are prepared explicitly by scripts/native/prepare_apple_runtime.sh.
// The device framework remains the pinned upstream Metal build; simulator uses
// the same llama.cpp commit compiled for that actual SDK, never a mock runtime.
let package = Package(
    name: "JarvisNativeLlama",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LlamaSwift", targets: ["LlamaSwift"])],
    targets: [
        .binaryTarget(name: "llama-cpp", path: ".artifacts/llama.xcframework"),
        .target(name: "LlamaSwift", dependencies: ["llama-cpp"])
    ]
)
