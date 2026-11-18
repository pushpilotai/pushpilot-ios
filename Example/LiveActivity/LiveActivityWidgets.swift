import Foundation
import PushPilotLive
import SwiftUI
import WidgetKit

/// The example's Widget Extension: PushPilot's default widget draws every PushPilot live activity on the
/// Lock Screen and in the Dynamic Island. The App Group comes from the PUSHPILOT_APP_GROUP build setting,
/// the same one the app passes to `initialize`; empty means none, and image blocks show their fallback icon.
@main
struct LiveActivityWidgets: WidgetBundle {
    var body: some Widget {
        PushPilotLiveActivityWidget(appGroup: appGroup)
    }

    /// The App Group from Info.plist, or nil when the build set none.
    private var appGroup: String? {
        let group = Bundle.main.object(forInfoDictionaryKey: "PushPilotAppGroup") as? String ?? ""
        return group.isEmpty ? nil : group
    }
}
