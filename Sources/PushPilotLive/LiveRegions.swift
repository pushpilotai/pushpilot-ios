#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI
import WidgetKit

/// The Lock Screen view of a layout: `lock` across the whole card, its `bg` edge to edge, the card
/// clipped; on iOS 18 and later the `small` view for the Apple Watch Smart Stack and CarPlay.
@available(iOS 16.1, *)
struct LiveLockView: View {
    let layout: LiveJSON
    let content: LiveContent

    /// The lock view, or on iOS 18 and later whichever the activity family asks for.
    var body: some View {
        if #available(iOS 18.0, *) {
            LiveFamilyView(layout: layout, content: content)
        } else {
            Self.lock(layout, content)
        }
    }

    /// The `lock` block filling the card's width; a version 1 block with neither `bg` nor `pad` keeps the
    /// 14 point margin it was designed with.
    static func lock(_ layout: LiveJSON, _ content: LiveContent) -> some View {
        let block = layout["lock"] ?? .null
        let bare = block["bg"] == nil && block["pad"] == nil
        return PushPilotLiveBlock(block, content: content, defs: layout["defs"], fill: LiveFill(width: true))
            .padding(bare ? 14 : 0)
            .clipped()
    }

    /// The `small` view, or the first `icon` of `lock` beside `{{title}}`.
    static func small(_ layout: LiveJSON, _ content: LiveContent) -> some View {
        let block = layout["small"] ?? .object(["type": .string("row"), "spacing": .number(8), "items": .array(
            [PushPilotLiveActivityWidget.first(["icon"], in: layout["lock"]),
             .object(["type": .string("text"), "text": .string("{{title}}"), "style": .string("title")])].compactMap { $0 })])
        return PushPilotLiveBlock(block, content: content, defs: layout["defs"], fill: LiveFill(width: true, height: true)).clipped()
    }

    /// The activity's background tint: the `bg` of `lock`, so it fills the card edge to edge.
    static func background(_ layout: LiveJSON, _ content: LiveContent) -> Color? {
        PushPilotLiveBlock(.null, content: content).color(layout["lock"]?["bg"]?.string)
    }
}

/// Chooses the `small` view for the small activity family (Apple Watch, CarPlay) and `lock` otherwise.
@available(iOS 18.0, *)
struct LiveFamilyView: View {
    let layout: LiveJSON
    let content: LiveContent
    @Environment(\.activityFamily) private var family

    /// The view for the current family.
    var body: some View {
        if family == .small {
            LiveLockView.small(layout, content)
        } else {
            LiveLockView.lock(layout, content)
        }
    }
}

@available(iOS 16.1, *)
extension WidgetConfiguration {
    /// Offers the small activity family (Apple Watch Smart Stack, CarPlay) where iOS 18 or later has it.
    func smallFamily() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}
#endif
