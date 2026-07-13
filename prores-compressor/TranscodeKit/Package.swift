// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranscodeKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "TranscodeKit", targets: ["TranscodeKit"]),
        .library(name: "DCPKit", targets: ["DCPKit"]),
    ],
    targets: [
        // Probing + MP4 export (AVFoundation/VideoToolbox).
        .target(
            name: "TranscodeKit"
        ),

        // DCP export pipeline (color transform, J2K, MXF, packaging, validation).
        .target(
            name: "DCPKit",
            dependencies: ["TranscodeKit", "COpenJPEG", "CASDCP"],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),

        // Vendored OpenJPEG 2.5.4 (BSD-2) — DCI-profile JPEG 2000 encoding.
        // See VENDORED.md for provenance and update instructions.
        .target(
            name: "COpenJPEG",
            cSettings: [
                .define("MUTEX_pthread", to: "1"),
                .headerSearchPath("."),
            ]
        ),

        // Vendored asdcplib (BSD) — SMPTE MXF track files. Built WITHOUT_SSL
        // (unencrypted DCPs only; asdcplib's own SHA-1/AES stand-ins are used).
        // Swift touches only include/asdcp_shim.h. See VENDORED.md.
        .target(
            name: "CASDCP",
            cxxSettings: [
                .define("ASDCP_PLATFORM", to: "\"unix\""),
                .define("PACKAGE_VERSION", to: "\"2.13.1-905d604\""),
                // asdcplib includes its own headers with <angle brackets>.
                .headerSearchPath("."),
            ]
        ),

        .testTarget(
            name: "TranscodeKitTests",
            dependencies: ["TranscodeKit"]
        ),
        .testTarget(
            name: "DCPKitTests",
            dependencies: ["DCPKit"]
        ),
    ],
    cxxLanguageStandard: .cxx14
)
