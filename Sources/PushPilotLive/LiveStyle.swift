#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI

/// A rectangle with its own radius at each corner (`radius` as four numbers), insettable so a `border`
/// is drawn inside the box.
struct LiveCorners: InsettableShape {
    /// Top leading, top trailing, bottom trailing, bottom leading.
    var radii: [CGFloat]
    var inset: CGFloat = 0

    /// The outline in `rect`, each radius limited to half the shorter side.
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let limit = min(r.width, r.height) / 2
        let c = (0..<4).map { min(max((radii.indices.contains($0) ? radii[$0] : 0) - inset, 0), limit) }
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c[0], y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: c[1])
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: c[2])
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: c[3])
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: c[0])
        p.closeSubpath()
        return p
    }

    /// The same corners moved inward by `amount`.
    func inset(by amount: CGFloat) -> LiveCorners {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// A `shape` `line`: through the middle of its box along the longer side, ends pulled in by half the
/// width when capped round so the stroke stays inside the box.
struct LiveLine: Shape {
    var pullIn: CGFloat

    /// The line in `rect`.
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if rect.width >= rect.height {
            p.move(to: CGPoint(x: rect.minX + pullIn, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX - pullIn, y: rect.midY))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.minY + pullIn))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - pullIn))
        }
        return p
    }
}

/// A piece of an `arc` between two angles (0 at 12 o'clock, clockwise), as a stroke centre line inset by
/// half the stroke, or as a pie wedge, in the largest square of the box.
struct LiveArcShape: Shape {
    var from: Double
    var to: Double
    var inset: CGFloat
    var wedge: Bool

    /// The arc in `rect`.
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - inset
        var p = Path()
        guard radius > 0 else { return p }
        if wedge { p.move(to: center) }
        // SwiftUI's angles start at 3 o'clock, and `clockwise: false` turns clockwise on screen.
        p.addArc(center: center, radius: radius, startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        if wedge { p.closeSubpath() }
        return p
    }
}

@available(iOS 16.1, *)
extension PushPilotLiveBlock {
    /// A layout colour: `#RRGGBB`, `#RRGGBBAA`, `accent`, `primary`, `secondary`, or inside a def `$name`
    /// from the `use`'s `colors` (primary when unset); nil keeps the default.
    func color(_ name: String?) -> Color? {
        switch name {
        case let value? where value.hasPrefix("$"): return color(palette[String(value.dropFirst())] ?? "primary")
        case "accent"?: return content.accent.flatMap(Self.hex)
        case "primary"?: return .primary
        case "secondary"?: return .secondary
        case let value?: return Self.hex(value)
        default: return nil
        }
    }

    /// Parses `#RRGGBB` and `#RRGGBBAA`.
    static func hex(_ value: String) -> Color? {
        guard value.count == 7 || value.count == 9, value.first == "#", let raw = UInt64(value.dropFirst(), radix: 16) else { return nil }
        let rgba = value.count == 7 ? raw << 8 | 0xff : raw
        return Color(.sRGB, red: Double((rgba >> 24) & 0xff) / 255, green: Double((rgba >> 16) & 0xff) / 255,
                     blue: Double((rgba >> 8) & 0xff) / 255, opacity: Double(rgba & 0xff) / 255)
    }

    /// A stroke: `width`, `cap` (`round` unless `butt`, so `dash` dots work) and `dash`, lengths times `scale`.
    func strokeStyle(_ b: LiveJSON, width fallback: CGFloat = 1, scale: CGFloat = 1, defaultCap: CGLineCap = .round) -> StrokeStyle {
        let cap: CGLineCap = b["cap"]?.string == "butt" ? .butt : b["cap"]?.string == "round" ? .round : defaultCap
        let dash = b["dash"]?.items.compactMap(\.number).map { CGFloat($0) * scale } ?? []
        return StrokeStyle(lineWidth: CGFloat(b["width"]?.number ?? Double(fallback)) * scale, lineCap: cap,
                           lineJoin: .round, dash: dash.contains { $0 > 0 } ? dash : [])
    }

    /// A number key as points, or nil.
    func points(_ json: LiveJSON?) -> CGFloat? { json?.number.map { CGFloat($0) } }

    /// The font of a text or timer block: its `style`, or `size` with the style's weight, then `weight`,
    /// `italic` and `mono`.
    func font(style: String?, size: Double?, weight name: String?, italic: Bool, mono: Bool) -> Font {
        var font: Font
        let base: Font.Weight? = style == "title" || style == "headline" ? .semibold : style == "number" ? .bold : nil
        if let size {
            font = .system(size: CGFloat(size), weight: base ?? .regular, design: style == "number" ? .rounded : .default)
        } else {
            switch style {
            case "title"?: font = .headline
            case "headline"?: font = .subheadline.weight(.semibold)
            case "caption"?: font = .caption
            case "number"?: font = .system(size: 28, weight: .bold, design: .rounded)
            default: font = .subheadline
            }
        }
        if let w = weight(name) { font = font.weight(w) }
        if italic { font = font.italic() }
        if mono || style == "number" { font = font.monospacedDigit() }
        return font
    }

    /// The point size a text block draws at, for `tracking` in em.
    func fontSize(style: String?, size: Double?) -> CGFloat {
        if let size { return CGFloat(size) }
        switch style {
        case "title"?: return 17
        case "caption"?: return 12
        case "number"?: return 28
        default: return 15
        }
    }

    /// A text weight name as a font weight.
    func weight(_ name: String?) -> Font.Weight? {
        switch name {
        case "regular"?: return .regular
        case "medium"?: return .medium
        case "semibold"?: return .semibold
        case "bold"?: return .bold
        case "heavy"?: return .heavy
        case "black"?: return .black
        default: return nil
        }
    }

    /// Where `at` puts a block inside a layer (default centre).
    static func alignment(_ at: String?) -> Alignment {
        switch at {
        case "top_leading"?: return .topLeading
        case "top"?: return .top
        case "top_trailing"?: return .topTrailing
        case "leading"?: return .leading
        case "trailing"?: return .trailing
        case "bottom_leading"?: return .bottomLeading
        case "bottom"?: return .bottom
        case "bottom_trailing"?: return .bottomTrailing
        default: return .center
        }
    }
}
#endif
