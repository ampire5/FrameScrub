// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Command Line Tools ship the swift-testing macro plugin outside the default search path. Only for them: with Xcode
// selected its compiler finds its own plugin, and the Command Line Tools' one (another version) would shadow it.
let testingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
let usesCommandLineTools = developerDir.hasPrefix("/Library/Developer/CommandLineTools")

let package = Package(
    name: "FrameScrub",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "FrameScrub", targets: ["FrameScrub"])],
    // lts/macos26: the kits' LTS branches, which take the same backports as this one (LTS_POLICY.md).
    dependencies: [
        .package(url: "https://github.com/ampire5/LogiHIDPP.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/InfoPanelKit.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/StashKit.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/HomeScreenKit.git", branch: "lts/macos26"),
        .package(url: "https://github.com/ampire5/SettingsKit.git", branch: "lts/macos26"),
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat libavcodec libavutil libswresample libswscale",
            providers: [.brew(["ffmpeg"])]
        ),
        .target(
            name: "FrameScrubCore",
            dependencies: [
                "CFFmpeg",
                .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                .product(name: "InfoPanelModel", package: "InfoPanelKit"),
                .product(name: "HomeScreenModel", package: "HomeScreenKit"),
                .product(name: "StashKit", package: "StashKit"),
            ]
        ),
        .executableTarget(
            name: "FrameScrub",
            dependencies: [
                "FrameScrubCore",
                .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                .product(name: "InfoPanelKit", package: "InfoPanelKit"),
                .product(name: "StashKitUI", package: "StashKit"),
                .product(name: "HomeScreenKit", package: "HomeScreenKit"),
                .product(name: "SettingsKit", package: "SettingsKit"),
            ]
        ),
        .testTarget(
            name: "FrameScrubCoreTests",
            dependencies: [
                "FrameScrubCore",
                "CFFmpeg",
                .product(name: "LogiHIDPP", package: "LogiHIDPP"),
                .product(name: "InfoPanelModel", package: "InfoPanelKit"),
                .product(name: "HomeScreenModel", package: "HomeScreenKit"),
                .product(name: "StashKit", package: "StashKit"),
            ],
            swiftSettings: usesCommandLineTools ? [.unsafeFlags(["-plugin-path", testingPluginPath])] : []
        ),
    ],
    swiftLanguageModes: [.v5]
)
