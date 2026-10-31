// swift-tools-version:5.9
//
// whisper.cpp, prebuilt by the whisper.cpp project as an XCFramework
// (https://github.com/ggml-org/whisper.cpp/releases/tag/b5454).
// Bundling it lets OpenClicky run any Whisper ggml model on-device,
// including models downloaded by other apps such as Superwhisper,
// without installing anything else. Uses Metal on Apple silicon.
//
// To update: point `url` at a newer whisper-<tag>-xcframework.zip and set
// `checksum` to the output of `swift package compute-checksum <zip>`.
import PackageDescription

let package = Package(
    name: "WhisperFramework",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperFramework", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        )
    ]
)
