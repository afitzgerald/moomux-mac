import AppKit

/// Keeps macOS 27's "Ask Siri" header out of this app's context menus.
///
/// AppKit inserts it into every context menu as a private `NSCampoMenuItem`,
/// in a one-item menu of its own, and there is no public switch:
/// `automaticallyInsertsWritingToolsItems = false` leaves it there. So it is
/// removed the moment it is added, matched by class name rather than by its
/// localized title. Ceiling: if Apple renames the class, the item comes back
/// (nothing breaks); the upgrade is a public opt-out if one ever ships.
enum NoAskSiri {
    private static var observer: NSObjectProtocol?

    @MainActor static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: nil
        ) { note in
            guard let menu = note.object as? NSMenu,
                  let index = note.userInfo?["NSMenuItemIndex"] as? Int,
                  menu.items.indices.contains(index),
                  NSStringFromClass(type(of: menu.items[index])) == "NSCampoMenuItem"
            else { return }
            menu.removeItem(at: index)
        }
    }
}
