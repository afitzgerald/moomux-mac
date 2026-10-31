import Foundation

/// MoomuxKit's SwiftPM resource bundle, for the Mac app to resolve once at
/// launch — see `GhosttyResourceBundle.warm()`, which needs it public.
public enum KitBundle {
    public static var bundle: Bundle { .module }
}
