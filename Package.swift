// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode on purpose: strict concurrency would want the socket
// client to be an actor, and it is a blocking file descriptor wrapped in
// Task.detached. Revisit when there is a reason to.
let package = Package(
    name: "Moomux",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The one dependency: Ghostty's terminal engine, as a prebuilt
        // xcframework wrapped in a Swift package (MIT). Reached only through
        // UI/TerminalPane.swift and UI/SessionGrid.swift.
        //
        // Why prebuilt and not built from ghostty source: upstream publishes
        // releases for libghostty-*vt* only — a VT parser with no renderer and
        // no pty. The embeddable library that has both is built with
        // `zig build -Demit-xcframework=true`, whose last step is
        // `xcodebuild -create-xcframework`. That is only half the job anyway:
        // the C API hands over no AppKit surface, so key translation, IME,
        // mouse, selection and the app runtime would all be ours (Ghostty's own
        // are ~250KB of Swift; cmux's are ~25,000 lines over a ghostty fork).
        // This package is that layer, already written. See CLAUDE.md.
        //
        // Pinned exactly, not `from:`: releases are weekly `1.5.<YYYYMMDD>`
        // snapshots of an upstream API that is explicitly not stable yet, so a
        // bump is a deliberate act with a screenshot behind it.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.5.20260906")
    ],
    targets: [
        .executableTarget(
            name: "Moomux",
            dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-spm")],
            path: "Sources/Moomux",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
