#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Draws one block of a PushPilot layout (LIVE.md "Contract: layouts, fields and state" and "Contract
/// version 2: drawing pieces"). A block type it does not know draws nothing, so later layout versions still show.
@available(iOS 16.1, *)
public struct PushPilotLiveBlock: View {
    let block: LiveJSON
    var content: LiveContent
    /// The layout's shared drawings, for `use`.
    let defs: LiveJSON?
    let fill: LiveFill
    /// The `$name` colours of the def being drawn, set by the `use` that drew it.
    var palette: [String: String] = [:]
    /// The nearest enclosing layer's or def's `view`, for a `path` or `use` without one.
    var viewBox: CGSize?

    /// A block drawn with an activity's content; `defs` is the layout's `defs`, needed when it uses any.
    public init(_ block: LiveJSON, content: LiveContent, defs: LiveJSON? = nil) {
        self.init(block, content: content, defs: defs, fill: LiveFill())
    }

    /// A block that takes the whole width or height its parent offers (the Lock Screen card's width).
    init(_ block: LiveJSON, content: LiveContent, defs: LiveJSON?, fill: LiveFill) {
        self.block = block
        self.content = content
        self.defs = defs
        self.fill = fill
    }

    public var body: some View { draw(block, fill) }

    /// The block types this renderer draws.
    static let types: Set<String> = ["row", "column", "spacer", "text", "badge", "icon", "image", "progress", "timer", "pairs",
                                     "layer", "shape", "arc", "path", "use", "chart", "grid"]

    /// One block as a view inside its box; nesting deeper than any valid layout, or a `show` that does not
    /// hold, draws nothing.
    func draw(_ raw: LiveJSON, _ parentFill: LiveFill = LiveFill(), depth: Int = 0) -> AnyView {
        guard depth < 24, content.shows(raw["show"]) else { return AnyView(EmptyView()) }
        let b = placed(raw)
        let fill = LiveFill(width: parentFill.width || b["fw"] != nil, height: parentFill.height || b["fh"] != nil)
        // A hidden item takes no space, so it is left out before the layout sees it.
        let items = (b["items"]?.items ?? []).prefix(16).filter { content.shows($0["show"]) }.map(placed)
        let childFraction = { (key: String) in items.contains { $0[key] != nil } }
        switch b["type"]?.string {
        case "row", "column":
            let row = b["type"]?.string == "row"
            let stack = LiveStackLayout(horizontal: row, spacing: CGFloat(b["spacing"]?.number ?? 4), align: b["align"]?.string,
                                        fillMain: (row ? fill.width : fill.height) || childFraction(row ? "fw" : "fh"),
                                        fillCross: (row ? fill.height : fill.width) || childFraction(row ? "fh" : "fw")) { children(items, depth) }
            return AnyView(boxed(stack, b, fill: fill))
        case "layer":
            let inner = Self.viewSize(b["view"]).map { v in with { $0.viewBox = v } } ?? self
            let layer = LiveLayerLayout(fillWidth: fill.width || b["w"] != nil || childFraction("fw"),
                                        fillHeight: fill.height || b["h"] != nil || childFraction("fh")) { inner.children(items, depth) }
            return AnyView(boxed(layer, b, fill: fill))
        case "spacer":
            return AnyView(boxed(Spacer(minLength: 0), b, fill: fill).layoutValue(key: LiveSpacerKey.self, value: true))
        case "text":
            return AnyView(boxed(text(b), b, fill: fill, alignment: textBoxAlignment(b)))
        case "timer":
            return AnyView(boxed(timer(b), b, fill: fill, alignment: textBoxAlignment(b)))
        case "badge":
            return AnyView(boxed(Text(content.fill(b["text"]?.string)).font(.caption.bold()).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 2).foregroundColor(.white)
                .background(Capsule().fill(color(b["color"]?.string ?? "accent") ?? .gray)), b, fill: fill))
        case "icon":
            return AnyView(boxed(icon(b["name"]?.string, asset: b["asset"]?.string, size: b["size"], color: color(b["color"]?.string)), b, fill: fill))
        case "image":
            return AnyView(boxed(image(b), b, fill: fill))
        case "progress":
            return AnyView(boxed(progress(b), b, fill: fill))
        case "pairs":
            return AnyView(boxed(pairs(b), b, fill: fill))
        case "shape":
            return AnyView(boxed(shape(b), b, fill: fill))
        case "arc":
            return AnyView(boxed(arc(b), b, fill: fill))
        case "path":
            return AnyView(boxed(path(b, depth: depth), b, fill: fill))
        case "chart":
            return AnyView(boxed(chart(b), b, fill: fill))
        case "grid":
            return AnyView(boxed(grid(b, depth: depth), b, fill: fill))
        case "use":
            return AnyView(boxed(use(b, fill: fill, depth: depth), b, fill: fill))
        default:
            return AnyView(EmptyView())
        }
    }

    /// The shown items of a row, column or layer, first at the back.
    private func children(_ items: [LiveJSON], _ depth: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in draw(item, depth: depth + 1) }
    }

    /// This block drawer with some context changed, for a subtree (a def's colours, a layer's view, a cell's label).
    func with(_ change: (inout PushPilotLiveBlock) -> Void) -> PushPilotLiveBlock {
        var copy = self
        change(&copy)
        return copy
    }

    /// A `view` of two numbers as a size, or nil.
    static func viewSize(_ json: LiveJSON?) -> CGSize? {
        let v = json?.items.compactMap(\.number) ?? []
        return v.count == 2 ? CGSize(width: v[0], height: v[1]) : nil
    }

    /// Label and value rows.
    private func pairs(_ b: LiveJSON) -> some View {
        VStack(spacing: 2) {
            ForEach(Array((b["items"]?.items ?? []).enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(content.fill(item["label"]?.string)).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text(content.fill(item["value"]?.string)).fontWeight(.semibold)
                }.font(.subheadline).lineLimit(1)
            }
        }
    }

    /// An SF Symbol from the PushPilot list, or the app's own image; nothing for an unknown name. `size` is
    /// `s`, `m`, `l` or points from 8 to 120.
    @ViewBuilder
    private func icon(_ name: String?, asset: String?, size: LiveJSON?, color: Color?) -> some View {
        let points: CGFloat = size?.number.map { CGFloat(min(max($0, 8), 120)) } ?? (size?.string == "s" ? 14 : size?.string == "l" ? 28 : 20)
        if let asset, !asset.isEmpty {
            Image(asset).resizable().scaledToFit().frame(width: points, height: points)
        } else if let symbol = name.flatMap({ PushPilotLiveIcons.symbols[$0] }) {
            Image(systemName: symbol).font(.system(size: points)).foregroundColor(color)
        }
    }

    /// An image from the app, or from the App Group once the app downloaded it; the fallback icon until then.
    @ViewBuilder
    private func image(_ b: LiveJSON) -> some View {
        let side: CGFloat = b["size"]?.string == "s" ? 24 : b["size"]?.string == "l" ? 64 : 40
        let shape = b["shape"]?.string
        if let picture = picture(b) {
            picture.resizable().scaledToFill().frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: shape == "circle" ? side / 2 : shape == "rounded" ? side * 0.2 : 0))
        } else {
            icon(b["fallback"]?.string, asset: nil, size: b["size"], color: nil)
        }
    }

    /// The image of an image block, if it can be drawn now.
    private func picture(_ b: LiveJSON) -> Image? {
        if let asset = b["asset"]?.string, !asset.isEmpty { return Image(asset) }
        guard let url = b["url"]?.string, let group = content.appGroup,
              let file = LiveContent.imageFile(url: content.fill(url), appGroup: group),
              let image = UIImage(contentsOfFile: file.path) else { return nil }
        return Image(uiImage: image)
    }
}

/// The default widget for every PushPilot live activity: the layout's Lock Screen block, and its
/// Dynamic Island regions or their defaults. Return it from your Widget Extension's bundle:
///
/// ```swift
/// @main struct LiveWidgets: WidgetBundle {
///     var body: some Widget { PushPilotLiveActivityWidget(appGroup: "group.com.example.app") }
/// }
/// ```
@available(iOS 16.1, *)
public struct PushPilotLiveActivityWidget: Widget {
    let appGroup: String?

    /// `appGroup` is the App Group the app passes to `PushPilot.initialize`, so URL images can be shown.
    public init(appGroup: String?) { self.appGroup = appGroup }

    /// Without an App Group: URL images show their fallback icon.
    public init() { appGroup = nil }

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: PushPilotLiveAttributes.self) { context in
            let (layout, content) = Self.parts(context, appGroup)
            LiveLockView(layout: layout, content: content)
                .activityBackgroundTint(LiveLockView.background(layout, content))
                .widgetURL(Self.link(context.attributes))
        } dynamicIsland: { context in
            let (layout, content) = Self.parts(context, appGroup)
            let island = layout["island"]
            let expanded = ["leading", "trailing", "center", "bottom"].contains { island?[$0] != nil }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Self.view(island?["leading"], layout, content) }
                DynamicIslandExpandedRegion(.trailing) { Self.view(island?["trailing"], layout, content) }
                DynamicIslandExpandedRegion(.center) { Self.view(island?["center"], layout, content) }
                DynamicIslandExpandedRegion(.bottom) { Self.view(expanded ? island?["bottom"] : layout["lock"], layout, content) }
            } compactLeading: {
                Self.view(island?["compact_leading"] ?? Self.first(["icon", "image"], in: layout["lock"]), layout, content)
            } compactTrailing: {
                Self.view(island?["compact_trailing"] ?? Self.first(["timer", "progress"], in: layout["lock"]), layout, content)
            } minimal: {
                Self.view(island?["minimal"] ?? Self.first(["timer", "progress"], in: layout["lock"]), layout, content)
            }
            .widgetURL(Self.link(context.attributes))
            .keylineTint(context.attributes.accent.flatMap(PushPilotLiveBlock.hex))
        }
        .smallFamily()
    }

    /// The layout and the content for a context.
    static func parts(_ context: ActivityViewContext<PushPilotLiveAttributes>, _ group: String?) -> (LiveJSON, LiveContent) {
        let a = context.attributes
        return (a.layout, LiveContent(state: context.state, fields: a.fields, accent: a.accent, appGroup: group))
    }

    /// A block of a layout, or nothing.
    @ViewBuilder
    static func view(_ block: LiveJSON?, _ layout: LiveJSON, _ content: LiveContent) -> some View {
        if let block { PushPilotLiveBlock(block, content: content, defs: layout["defs"]) }
    }

    /// The first block of one of `types` in a tree, depth first.
    static func first(_ types: [String], in block: LiveJSON?) -> LiveJSON? {
        guard let block else { return nil }
        if let type = block["type"]?.string, types.contains(type) { return block }
        return block["items"]?.items.lazy.compactMap { first(types, in: $0) }.first
    }

    /// The tap link: the activity's `url` (or `pushpilot-live://open`) with `pushpilot_live=<start id>`,
    /// which `PushPilot.handleLiveActivityURL` records as a click and removes.
    public static func link(_ attributes: PushPilotLiveAttributes) -> URL? {
        var parts = URLComponents(string: attributes.url ?? "pushpilot-live://open") ?? URLComponents(string: "pushpilot-live://open")!
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: LiveLink.marker, value: attributes.notificationId)]
        return parts.url
    }
}
#endif

/// The query item a live activity's tap link carries.
public enum LiveLink {
    public static let marker = "pushpilot_live"
}
