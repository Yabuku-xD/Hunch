// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Swift Testing under the Command Line Tools: their swift-build never hands the TestingMacros plugin to the compiler,
// so load it explicitly when DEVELOPER_DIR points at the CLT (Xcode toolchains find it themselves).
// Scripts/test.sh is the reliable entry point; it passes the same flag and uses its own scratch path.
let cltDeveloperDir = "/Library/Developer/CommandLineTools"
let cltTestingPlugin = cltDeveloperDir + "/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let developerDir = Context.environment["DEVELOPER_DIR"] ?? cltDeveloperDir
let testingPluginFlags: [SwiftSetting] =
    developerDir.hasPrefix(cltDeveloperDir)
        && FileManager.default.fileExists(atPath: cltTestingPlugin)
    ? [.unsafeFlags(["-load-plugin-library", cltTestingPlugin])]
    : []

// llama.cpp + ggml + mtmd come from ggml-org's official xcframework, pinned to release b11669 (the build Homebrew's
// llama.cpp 0.7.0 ships, so behaviour and benchmarks match). Bump tag and checksum together; see CONTRIBUTING.md.
// `HUNCH_LLAMA=homebrew swift build` links the Homebrew kegs instead (unsupported, local perf work only; macOS 27).
let useHomebrewLlama = Context.environment["HUNCH_LLAMA"] == "homebrew"

let llamaTargets: [Target] =
    useHomebrewLlama
    ? [
        .systemLibrary(
            name: "CLlama",
            path: "Sources/CLlama",
            pkgConfig: "llama",
            providers: [.brew(["llama.cpp"])]
        )
    ]
    : [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
            checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
        )
    ]
let llamaDependency: Target.Dependency = useHomebrewLlama ? "CLlama" : "llama"

// Homebrew path only: llama.h includes ggml.h from the separate `ggml` keg, and the rpaths serve debug builds and
// tests (Scripts/make-app.sh bundles the dylibs).
let ggmlInclude: [SwiftSetting] =
    useHomebrewLlama ? [.unsafeFlags(["-Xcc", "-I/opt/homebrew/opt/ggml/include"])] : []
let llamaLinker: [LinkerSetting] =
    useHomebrewLlama
    ? [
        .unsafeFlags([
            "-L/opt/homebrew/opt/ggml/lib",
            "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/opt/llama.cpp/lib",
            "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/opt/ggml/lib",
        ])
    ]
    : []

// The engine's hot loops (name scan, top-k, fusion) run 10–20× slower at -Onone, which turns a sub-millisecond
// name pass into 5–9 ms and makes the debug build's --measure (first_results_ms ≤ 16) meaningless. HunchCore is
// always optimized; the app target stays at -Onone for debugging.
let hunchCoreOptimized: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

// The app's test target (PanelLayoutTests and friends) exists once Tests/HunchTests has sources.
let appTestsPath = Context.packageDirectory + "/Tests/HunchTests"
let appTestTargets: [Target] =
    FileManager.default.fileExists(atPath: appTestsPath)
    ? [
        .testTarget(
            name: "HunchTests",
            dependencies: ["Hunch"],
            swiftSettings: ggmlInclude + testingPluginFlags
        )
    ]
    : []

let package = Package(
    name: "Hunch",
    // The xcframework's macOS slice has minos 13.3 and the UI needs macOS 26 (Liquid Glass). The Homebrew bottles
    // are built for macOS 27, so the fallback keeps 27.
    platforms: [useHomebrewLlama ? .macOS("27.0") : .macOS(.v26)],
    products: [
        .library(name: "HunchCore", targets: ["HunchCore"]),
        .executable(name: "Hunch", targets: ["Hunch"]),
        .executable(name: "hunch-bench", targets: ["hunch-bench"]),
    ],
    targets: llamaTargets + [
        .target(
            name: "HunchCore",
            dependencies: [llamaDependency],
            swiftSettings: ggmlInclude + hunchCoreOptimized,
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("compression"),
                .linkedFramework("Accelerate"),
                // Content extraction: OCR, speech, video frames, PDF text, thumbnails.
                .linkedFramework("Vision"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("PDFKit"),
                .linkedFramework("QuickLookThumbnailing"),
            ] + llamaLinker
        ),
        .executableTarget(
            name: "Hunch",
            dependencies: ["HunchCore"],
            swiftSettings: ggmlInclude,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "hunch-bench",
            dependencies: ["HunchCore"],
            swiftSettings: ggmlInclude
        ),
        .testTarget(
            name: "HunchCoreTests",
            dependencies: ["HunchCore"],
            swiftSettings: ggmlInclude + testingPluginFlags
        ),
    ] + appTestTargets,
    swiftLanguageModes: [.v6]
)
