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
                "AgentChannel",
                "MediaSession",
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

        // -- SMT/1, SolStream's own media transport --
        //
        // Everything the GameStream path used to do between the socket and the
        // decoder: the AEAD, the replay window, video reassembly, input events
        // and the feedback that asks for a keyframe. It depends on nothing but
        // CryptoKit and the logger, which is what lets StreamConnection depend
        // on IT rather than the other way round -- the media key schedule lives
        // here and the agent channel borrows it.
        .target(
            name: "MediaSession",
            dependencies: ["SolStreamLogging"],
            path: "Sources/MediaSession"
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
            dependencies: ["SolStreamLogging", "MediaSession"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),  // For HID keycode mapping
            ]
        ),

        // -- The agent channel: TCP 47630, newline-JSON, sixteen commands --
        //
        // Named StreamConnection until the GameStream client that lived beside
        // it was deleted. What is left is the channel that was never GameStream:
        // app enumeration, window placement, the clipboard, the cursor shape,
        // and the handshake that agrees the media keys.
        .target(
            name: "AgentChannel",
            dependencies: ["SolStreamLogging", "MediaSession"],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics"),
            ]
        ),



        // -- UI Tests --
        .testTarget(
            name: "SolStreamClientTests",
            dependencies: ["SolStreamClient", "SolStreamLogging",
                           "AgentChannel", "MediaSession",
                           "VideoDecoder", "AudioRenderer"],
            linkerSettings: [
                .linkedFramework("XCTest"),
            ]
        ),
    ]
)
