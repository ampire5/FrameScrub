// swift-tools-version: 6.2
import PackageDescription

// Command Line Tools ship the swift-testing macro plugin outside the default search path.
let testingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

let package = Package(
    name: "FrameScrub",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "FrameScrub", targets: ["FrameScrub"])],
    dependencies: [
        .package(url: "https://github.com/ampire5/LogiHIDPP.git", from: "0.1.0"),
        .package(url: "https://github.com/ampire5/InfoPanelKit.git", from: "0.1.0"),
        .package(url: "https://github.com/ampire5/StashKit.git", from: "0.1.0"),
        .package(url: "https://github.com/ampire5/HomeScreenKit.git", from: "0.1.0"),
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
            swiftSettings: [.unsafeFlags(["-plugin-path", testingPluginPath])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
