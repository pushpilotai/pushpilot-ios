#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI

/// Whether a block must take the whole size its parent offers, per axis: a `fw`/`fh` share, a grid
/// cell, or the Lock Screen card's width.
struct LiveFill {
    var width = false
    var height = false
}

/// The box keys every block may have (LIVE.md "Contract version 2"), applied in the contract's order:
/// size, `pad`, `bg` and `border`, `clip`, then `offset`, `rotate` and `opacity`.
@available(iOS 16.1, *)
struct LiveBoxModifier: ViewModifier {
    let block: LiveJSON
    let fill: LiveFill
    /// Where content smaller than its box sits.
    let alignment: Alignment
    let background: Color?
    let border: Color?
    /// The block's turn in degrees, already resolved from a bound value.
    let rotation: Double

    /// The content inside its box. Each key is applied only when present: a frame that is not needed can
    /// still snap its content to the pixel grid and cut the last letter of a text, and the widget's memory is tight.
    func body(content: Content) -> some View {
        let shape = LiveCorners(radii: radii)
        let b = block
        let opacity = b["opacity"]?.number ?? 1
        content
            .liveIf(b["pad"] != nil) { $0.padding(insets) }
            .liveIf(b["w"] != nil || b["h"] != nil) { $0.frame(width: size("w"), height: size("h"), alignment: alignment) }
            // An own `w` or `h` wins over filling, so a fixed-width block's background stays its width.
            .liveIf(fill.width && b["w"] == nil || fill.height && b["h"] == nil) {
                $0.frame(maxWidth: fill.width && b["w"] == nil ? .infinity : nil, maxHeight: fill.height && b["h"] == nil ? .infinity : nil, alignment: alignment)
            }
            .liveIf(background != nil) { $0.background(shape.fill(background ?? .clear)) }
            .liveIf(border != nil) {
                let dash = (b["border"]?["dash"]?.items ?? []).compactMap(\.number).map { CGFloat($0) }
                return $0.overlay(shape.strokeBorder(border ?? .clear, style: StrokeStyle(lineWidth: CGFloat(b["border"]?["width"]?.number ?? 1),
                                                                                         dash: dash.contains { $0 > 0 } ? dash : [])))
            }
            .liveIf(b["clip"] == .bool(true)) { $0.clipShape(shape) }
            .liveIf(rotation != 0) { $0.rotationEffect(.degrees(rotation)) }
            .liveIf(b["offset"] != nil) { $0.offset(x: offset(0), y: offset(1)) }
            .liveIf(opacity != 1) { $0.opacity(opacity) }
    }

    /// `w` or `h` in points, or nil.
    private func size(_ key: String) -> CGFloat? { block[key]?.number.map { CGFloat(max($0, 0)) } }

    /// `pad` as one number or `[top, trailing, bottom, leading]`.
    private var insets: EdgeInsets {
        if let all = block["pad"]?.number { return EdgeInsets(top: all, leading: all, bottom: all, trailing: all) }
        let p = (block["pad"]?.items ?? []).compactMap(\.number).map { CGFloat($0) }
        guard p.count == 4 else { return EdgeInsets() }
        return EdgeInsets(top: p[0], leading: p[3], bottom: p[2], trailing: p[1])
    }

    /// `radius` as one number or four corners.
    private var radii: [CGFloat] {
        if let all = block["radius"]?.number { return Array(repeating: CGFloat(all), count: 4) }
        return (block["radius"]?.items ?? []).compactMap(\.number).map { CGFloat($0) }
    }

    /// One coordinate of `offset`.
    private func offset(_ i: Int) -> CGFloat {
        let o = block["offset"]?.items ?? []
        return o.count == 2 ? CGFloat(o[i].number ?? 0) : 0
    }
}

extension View {
    /// The view changed by `transform` when `condition` holds, else unchanged.
    @ViewBuilder
    func liveIf<V: View>(_ condition: Bool, _ transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }
}

@available(iOS 16.1, *)
extension PushPilotLiveBlock {
    /// A block's view inside its box, tagged with what its parent reads (`at`, `fw`/`fh`).
    func boxed<V: View>(_ view: V, _ b: LiveJSON, fill: LiveFill, alignment: Alignment = .center) -> some View {
        let fw = content.amount(b["fw"]), fh = content.amount(b["fh"])
        let fraction = fw == nil && fh == nil ? nil : CGSize(width: fw ?? -1, height: fh ?? -1)
        return view
            .modifier(LiveBoxModifier(block: b, fill: fill, alignment: alignment, background: color(b["bg"]?.string),
                                      border: color(b["border"]?["color"]?.string), rotation: rotation(b["rotate"])))
            .layoutValue(key: LiveAtKey.self, value: Self.alignment(b["at"]?.string))
            .layoutValue(key: LiveFractionKey.self, value: fraction)
            .layoutValue(key: LivePosKey.self, value: content.pos(b["pos"]))
    }

    /// `rotate`: constant degrees, or `{"value", "from", "to"}` turning with an amount.
    func rotation(_ json: LiveJSON?) -> Double {
        if let degrees = json?.number { return degrees }
        guard let json, case .object = json else { return 0 }
        let from = json["from"]?.number ?? 0, to = json["to"]?.number ?? 360
        return from + (to - from) * (content.amount(json["value"]) ?? 0)
    }
}
#endif
