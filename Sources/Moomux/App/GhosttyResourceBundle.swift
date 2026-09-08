import Foundation
import GhosttyTerminal
import ObjectiveC

/// Makes libghostty's SwiftPM resource bundle findable from inside a `.app`.
///
/// SwiftPM's generated `Bundle.module` accessor looks in exactly two places:
/// `Bundle.main.bundleURL/GhosttyKit_GhosttyTerminal.bundle` — the *root* of the
/// app bundle — and an absolute `.build` path baked in when the binary was
/// compiled. It `fatalError`s when neither exists, and the package reads it
/// (`GhosttyRuntimeResources.configureEnvironment()`) while the first
/// `TerminalController` initialises the ghostty runtime. So on a machine that is
/// not the build machine, selecting a session killed the app outright:
///
///     Fatal error: could not load resource bundle: from
///     /Applications/Moomux.app/GhosttyKit_GhosttyTerminal.bundle or
///     /Users/runner/work/moomux-mac/.../GhosttyKit_GhosttyTerminal.bundle
///
/// The app root is not a legal home for it: `codesign` refuses to sign an app
/// bundle with anything but `Contents` there — "unsealed contents present in the
/// bundle root", then "code object is not signed at all" — for a directory and
/// for a symlink alike. Measured both ways. `Contents/Resources` is the only
/// place it can go, and that is the one place the accessor does not look. It
/// shipped because a build machine has the second candidate: `.build` is right
/// there on disk, so the bug is invisible exactly where it would be caught.
///
/// `Bundle(path:)` bottoms out in `-[NSBundle initWithPath:]`, so redirecting
/// that one call is the whole fix, and it beats forking the dependency for a
/// five-line patch that would need re-applying to every weekly snapshot. But an
/// `init` has ARC semantics Swift cannot express (it consumes `self` and returns
/// +1), and a hook over every `Bundle(path:)` in the process is a wide blast
/// radius for one lookup — a first attempt that let ARC touch either segfaulted
/// on launch. So `Unmanaged` on both ends, and the hook lives only as long as it
/// takes to force the lookup: `Bundle.module` is a `static let`, so warming it
/// here settles it for the life of the process and the original implementation
/// goes straight back.
enum GhosttyResourceBundle {
    static let name = "GhosttyKit_GhosttyTerminal.bundle"

    /// Where `make app` puts it. Nil unbundled (`make selfcheck`), where
    /// SwiftPM's own `.build` candidate is present and correct anyway.
    static var shippedPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent(name).path
    }

    /// The one rewrite: a request for the bundle at a path that has none, when
    /// we ship one, becomes a request for ours. Anything else passes through.
    static func redirect(_ path: String, shipped: String?, exists: (String) -> Bool) -> String {
        guard (path as NSString).lastPathComponent == name, !exists(path),
              let shipped, shipped != path, exists(shipped)
        else { return path }
        return shipped
    }

    /// Resolves the package's resource bundle once, before anything builds a
    /// `TerminalController`. Cheap enough to call unconditionally: with the
    /// bundle already where the accessor looks, it is one `Bundle(path:)`.
    static func warm() {
        let sel = NSSelectorFromString("initWithPath:")
        guard let method = class_getInstanceMethod(Bundle.self, sel) else { return }
        typealias Original =
            @convention(c) (Unmanaged<AnyObject>, Selector, NSString) -> Unmanaged<AnyObject>?
        let previous = method_getImplementation(method)
        let original = unsafeBitCast(previous, to: Original.self)
        let shipped = shippedPath
        let exists = FileManager.default.fileExists(atPath:)
        let hook: @convention(block) (Unmanaged<AnyObject>, NSString) -> Unmanaged<AnyObject>? = {
            object, path in
            original(object, sel, redirect(path as String, shipped: shipped, exists: exists) as NSString)
        }
        method_setImplementation(method, imp_implementationWithBlock(hook))
        _ = GhosttyRuntimeResources.directoryURL // the fatalError, or not, happens here
        method_setImplementation(method, previous)
    }

    static func demo() {
        let here = Set(["/App.app/Contents/Resources/\(name)", "/build/\(name)"])
        let exists: (String) -> Bool = { here.contains($0) }
        let shipped = "/App.app/Contents/Resources/\(name)"

        // The crash: the accessor asks at the app root, where nothing is.
        assert(redirect("/App.app/\(name)", shipped: shipped, exists: exists) == shipped)
        // A candidate that does exist is never second-guessed.
        assert(redirect("/build/\(name)", shipped: shipped, exists: exists) == "/build/\(name)")
        // Any other missing bundle stays missing — this is not a search path.
        assert(redirect("/App.app/Other.bundle", shipped: shipped, exists: exists)
               == "/App.app/Other.bundle")
        // Unbundled (`make selfcheck`): nothing shipped, nothing rewritten.
        assert(redirect("/App.app/\(name)", shipped: nil, exists: exists) == "/App.app/\(name)")
        // A shipped copy we cannot see is not worth handing back.
        assert(redirect("/App.app/\(name)", shipped: "/gone/\(name)", exists: exists)
               == "/App.app/\(name)")
    }
}
