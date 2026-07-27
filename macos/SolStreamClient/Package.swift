// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SolStreamClient",
    platforms: [
        .macOS(.v14)  // Required for VideoToolbox modern API, Metal 3
    ],
    products: [
        .executable(name: "SolStreamClient", targets: ["SolStreamClient"])
    ],
    dependencies: [],
    targets: [
        // -- Main application target --
        .executableTarget(
            name: "SolStreamClient",
            dependencies: [
                "VideoDecoder",
                "AudioRenderer",
                "InputCapture",
                "StreamConnection",
                "SolStreamLogging",
                "DesignSystem"
            ]
        ),

        // -- Design tokens (Nocturne), shared with the video overlay --
        .target(
            name: "DesignSystem",
            dependencies: [],
            path: "Sources/DesignSystem",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),

        // -- Shared logging module (used by all targets) --
        .target(
            name: "SolStreamLogging",
            dependencies: [],
            path: "Sources/SolStreamLogging"
        ),

        // -- Video decoder (VideoToolbox + CAMetalLayer) --
        .target(
            name: "VideoDecoder",
            dependencies: ["SolStreamLogging", "DesignSystem"],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),

        // -- Audio renderer (AudioUnit) --
        .target(
            name: "AudioRenderer",
            dependencies: ["SolStreamLogging"],
            linkerSettings: [
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),

        // -- Input capture (NSView local monitoring, no CGEventTap) --
        .target(
            name: "InputCapture",
            dependencies: ["SolStreamLogging", "StreamConnection"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),  // For HID keycode mapping
            ]
        ),

        // -- Stream connection (SRTP, WS control, pairing) --  
        .target(
            name: "StreamConnection",
            dependencies: ["SolStreamLogging", "CCommonCrypto", "CEnet"],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics"),
            ]
        ),

        // -- CommonCrypto bridging module --
        .target(
            name: "CCommonCrypto",
            dependencies: [],
            path: "Sources/CCommonCrypto"
        ),

        // -- ENET networking library --
        .target(
            name: "CEnet",
            dependencies: [],
            path: "Sources/CEnet",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),

        // -- UI Tests --
        .testTarget(
            name: "SolStreamClientTests",
            dependencies: ["SolStreamClient", "SolStreamLogging",
                           "StreamConnection", "VideoDecoder", "AudioRenderer"],
            linkerSettings: [
                .linkedFramework("XCTest"),
            ]
        ),
    ]
)
