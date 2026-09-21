// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode on purpose: strict concurrency would want the socket
// client to be an actor, and it is a blocking file descriptor wrapped in
// Task.detached. Revisit when there is a reason to.
let package = Package(
    name: "Moomux",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        // The engine is a library so an iOS app can link it. The Mac app stays
        // an executableTarget, so `make build` / `make selfcheck` keep working
        // under plain `swift build` exactly as before.
        // `type: .static` and not the default: an *automatic* library product
        // cannot be named by `swift build --product`, which is how `make ios`
        // asks for MoomuxKit alone — the default set drags in the macOS
        // executable and fails on `import AppKit`. Static is also what the iOS
        // app shell links (`libMoomuxKit.a`); `--target` builds the module
        // without emitting one. The Mac app depends on the target, not this
        // product, so its link is unchanged.
        .library(name: "MoomuxKit", type: .static, targets: ["MoomuxKit"])
    ],
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
        // Everything platform-independent: the wire types, the client, the
        // store and the two pure layout/form helpers. `ToolPath` lives here
        // too but compiles to nothing off macOS — `Process` is unavailable on
        // iOS, and the three features that shell out are guarded to match.
        //
        // swiftLanguageMode(.v5) has to be repeated on this target: without it
        // a new target defaults to Swift 6, strict concurrency turns on, and
        // the blocking-fd socket client is the first thing to break — the same
        // reason the note at the top of this file gives.
        .target(
            name: "MoomuxKit",
            dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-spm")],
            path: "Sources/MoomuxKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Moomux",
            dependencies: [
                "MoomuxKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/Moomux",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
