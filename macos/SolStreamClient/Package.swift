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
    dependencies: [
        // moonlight-common-c provides SRTP decoding/encoding and
        // the Moonlight streaming protocol implementation.
        // We bundle a vendored copy under Sources/CMoonlight for now.
    ],
    targets: [
        // ── Main application target ──────────────────────────────────────
        .executableTarget(
            name: "SolStreamClient",
            dependencies: [
                "CMoonlight",
                "VideoDecoder",
                "AudioRenderer",
                "InputCapture",
                "StreamConnection",
                "SolStreamLogging"
            ],
            resources: [
                .process("Resources")
            ]
        ),

        // ── Shared logging module (used by all targets) ──────────────────
        .target(
            name: "SolStreamLogging",
            dependencies: [],
            path: "Sources/SolStreamLogging"
        ),

        // ── Moonlight-common-c (vendored) ────────────────────────────────
        .target(
            name: "CMoonlight",
            dependencies: [],
            path: "Sources/CMoonlight",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("pthread"),
                .linkedLibrary("z"),
                .linkedFramework("CoreFoundation"),
            ]
        ),

        // ── Video decoder (VideoToolbox + CAMetalLayer) ──────────────────
        .target(
            name: "VideoDecoder",
            dependencies: ["CMoonlight", "SolStreamLogging"],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),

        // ── Audio renderer (AudioUnit) ───────────────────────────────────
        .target(
            name: "AudioRenderer",
            dependencies: ["CMoonlight", "SolStreamLogging"],
            linkerSettings: [
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),

        // ── Input capture (NSView local monitoring, no CGEventTap) ───────
        .target(
            name: "InputCapture",
            dependencies: ["SolStreamLogging"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),  // For HID keycode mapping
            ]
        ),

        // ── Stream connection (SRTP, WS control, pairing) ────────────────
        .target(
            name: "StreamConnection",
            dependencies: ["CMoonlight", "SolStreamLogging"],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
