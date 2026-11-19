#if canImport(UIKit) && canImport(WebKit)
import UIKit

extension PushPilot {
    /// Shows the first eligible cached in-app message whose trigger is `showInApp` with this `name`, with no
    /// network call. Returns whether a message is now shown; false when none is cached and eligible, or one is
    /// already on screen.
    @MainActor @discardableResult
    public static func showInApp(_ name: String) -> Bool {
        InAppController.shared.show(.named(name))
    }

    /// Names a view for coach-mark messages whose target is `name`. The SDK holds the view weakly; a coach mark
    /// shows only while the view is in a window, visible and on screen. A later view with the same name replaces it.
    @MainActor
    public static func markView(_ view: UIView, name: String) {
        InAppController.shared.mark(view, name: name)
    }

    /// Forgets the view marked with `name`.
    @MainActor
    public static func unmarkView(name: String) {
        InAppController.shared.unmark(name: name)
    }
}
#endif
