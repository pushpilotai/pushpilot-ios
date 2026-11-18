#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI

@available(iOS 16.1, *)
extension PushPilotLiveBlock {
    /// A `shape`: `rect` (with the box's `radius`), `circle`, `ellipse`, `capsule` or `line`, filled and
    /// stroked inside its box, which it fills unless sized.
    @ViewBuilder
    func shape(_ b: LiveJSON) -> some View {
        let fill = color(b["fill"]?.string), stroke = color(b["stroke"]?.string)
        let style = strokeStyle(b)
        switch b["shape"]?.string {
        case "circle"?: paint(Circle(), fill: fill, stroke: stroke, style: style)
        case "ellipse"?: paint(Ellipse(), fill: fill, stroke: stroke, style: style)
        case "capsule"?: paint(Capsule(), fill: fill, stroke: stroke, style: style)
        case "line"?:
            LiveLine(pullIn: style.lineCap == .round ? style.lineWidth / 2 : 0)
                .stroke(stroke ?? fill ?? .primary, style: style)
        default:
            let radius = b["radius"]?.number.map { [CGFloat($0)] } ?? (b["radius"]?.items ?? []).compactMap(\.number).map { CGFloat($0) }
            paint(LiveCorners(radii: radius.count == 1 ? Array(repeating: radius[0], count: 4) : radius), fill: fill, stroke: stroke, style: style)
        }
    }

    /// A shape's fill under its stroke, the stroke inside the outline; the accent fill when it has neither.
    private func paint<S: InsettableShape>(_ s: S, fill: Color?, stroke: Color?, style: StrokeStyle) -> some View {
        ZStack {
            if let fill { s.fill(fill) } else if stroke == nil { s.fill(color("accent") ?? .primary) }
            if let stroke { s.strokeBorder(stroke, style: style) }
        }
    }

    /// An `arc`: ring, gauge, wedge or ticks, in segments filled to its value, in the largest square of its
    /// box; between two times it is the system's circular timer progress, which runs by itself.
    @ViewBuilder
    func arc(_ b: LiveJSON) -> some View {
        let tint = color(b["color"]?.string ?? "accent") ?? .accentColor
        if let from = content.date(b["from"]?.string), let to = content.date(b["to"]?.string), to > from {
            // shortcut: the system's circular progress keeps only `color` (its own width); draw it ourselves if a later iOS can animate a custom one.
            ZStack {
                if let track = color(b["track"]?.string) { Circle().strokeBorder(track, lineWidth: CGFloat(b["width"]?.number ?? 4)) }
                ProgressView(timerInterval: from...to, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular).tint(tint)
            }
            .aspectRatio(1, contentMode: .fit)
        } else {
            let wedge = b["width"]?.number == nil
            let style = strokeStyle(b, width: 1)
            let inset = wedge ? 0 : style.lineWidth / 2
            let colors = (b["colors"]?.items ?? []).compactMap { color($0.string) }
            let track = color(b["track"]?.string)
            let pieces = LiveGeometry.arcPieces(start: rotation(b["start"]), sweep: b["sweep"]?.number ?? 360,
                                                segments: Int(min(max(b["segments"]?.number ?? 1, 1), 60)),
                                                gap: b["gap"]?.number ?? 0, value: content.amount(b["value"]) ?? 1)
            ZStack {
                ForEach(pieces, id: \.index) { piece in
                    let pieceColor = colors.isEmpty ? tint : colors[piece.index % colors.count]
                    if let track, piece.filledEnd < piece.end - 0.5 {
                        arcPiece(LiveArcShape(from: piece.start, to: piece.end, inset: inset, wedge: wedge), track, style, wedge)
                    }
                    if piece.filledEnd > piece.start + 0.5 { // under half a degree is a rounding sliver, not a fill
                        arcPiece(LiveArcShape(from: piece.start, to: piece.filledEnd, inset: inset, wedge: wedge), pieceColor, style, wedge)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    /// One arc piece, filled as a wedge or stroked as a band.
    @ViewBuilder
    private func arcPiece(_ s: LiveArcShape, _ c: Color, _ style: StrokeStyle, _ wedge: Bool) -> some View {
        if wedge { s.fill(c) } else { s.stroke(c, style: style) }
    }

    /// A `path`: SVG commands in its `view` box, fitted to the block's box, filled, stroked (width scaled
    /// with the drawing), trimmed, with a `marker` block centred on a point along it.
    func path(_ b: LiveJSON, depth: Int) -> some View {
        let segments = LivePathParser.parse(String((b["d"]?.string ?? "").prefix(1000))) ?? []
        let view = Self.viewSize(b["view"]) ?? viewBox ?? CGSize(width: 100, height: 100)
        let trim = content.amount(b["trim"]) ?? 1
        return GeometryReader { g in
            let (transform, scale) = LivePathGeometry.fit(view: view, into: CGRect(origin: .zero, size: g.size), fit: b["fit"]?.string)
            let full = Self.path(segments).applying(transform)
            let drawn = trim < 1 ? full.trimmedPath(from: 0, to: trim) : full
            ZStack {
                if let fill = color(b["fill"]?.string) { drawn.fill(fill) }
                if let stroke = color(b["stroke"]?.string) { drawn.stroke(stroke, style: strokeStyle(b, scale: scale)) }
                if let marker = b["marker"],
                   let point = LivePathGeometry.point(at: content.amount(b["marker_at"]) ?? trim,
                                                      in: LivePathGeometry.polylines(segments, transform: transform)) {
                    draw(marker, depth: depth + 1).position(point)
                }
            }
        }
    }

    /// Parsed segments as a SwiftUI path.
    static func path(_ segments: [LivePathSegment]) -> Path {
        var p = Path()
        for s in segments {
            switch s {
            case .move(let a): p.move(to: a)
            case .line(let a): p.addLine(to: a)
            case .quad(let c, let a): p.addQuadCurve(to: a, control: c)
            case .cubic(let c1, let c2, let a): p.addCurve(to: a, control1: c1, control2: c2)
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// A `chart` of `bar`s, a `line` or an `area`, split into `color` and `rest` at `split`, with a
    /// highlighted bar or point and an optional dot on the last point.
    func chart(_ b: LiveJSON) -> some View {
        let values = content.numbers(b["values"])
        let kind = b["kind"]?.string ?? "bar"
        let range = LiveGeometry.chartRange(values, min: b["min"]?.number, max: b["max"]?.number, bars: kind == "bar")
        let main = color(b["color"]?.string ?? "accent") ?? .accentColor
        let rest = color(b["rest"]?.string) ?? main
        let split = content.amount(b["split"]) ?? 1
        let highlight = content.value(b["highlight"]).map { Int($0.rounded()) }
        let marked = color(b["highlight_color"]?.string) ?? main
        let width = CGFloat(min(max(b["width"]?.number ?? 2, 0.5), 12))
        let dot: CGFloat? = b["dot"] == .bool(true) ? width * 3 : b["dot"]?.number.map { CGFloat($0) }
        return GeometryReader { g in
            let points = LiveGeometry.chartPoints(values, range: range, size: g.size)
            let splitX = g.size.width * CGFloat(split)
            ZStack(alignment: .topLeading) {
                if kind == "bar" {
                    bars(b, values, range, g.size) { i in i == highlight ? marked : CGFloat(i) + 0.5 <= CGFloat(values.count) * CGFloat(split) ? main : rest }
                } else {
                    let line = Self.polyline(points, closedTo: kind == "area" ? g.size.height : nil)
                    let paint = { (c: Color) in
                        kind == "area" ? AnyView(line.fill(c)) : AnyView(line.stroke(c, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)))
                    }
                    paint(rest)
                    paint(main).mask(alignment: .topLeading) { Rectangle().frame(width: splitX) }
                    if let h = highlight, points.indices.contains(h) {
                        Circle().fill(marked).frame(width: dot ?? width * 3, height: dot ?? width * 3).position(points[h])
                    }
                }
                if let dot, let last = points.last, kind != "bar" {
                    Circle().fill(color(b["highlight_color"]?.string) ?? main).frame(width: dot, height: dot).position(last)
                }
            }
        }
    }

    /// The bars of a bar chart, from the scale's zero (or bottom) up, or with `base: center` both ways from
    /// the middle line, `gap` apart, all four corners rounded with `round`.
    private func bars(_ b: LiveJSON, _ values: [Double], _ range: (Double, Double), _ size: CGSize, color: @escaping (Int) -> Color) -> some View {
        let gap = CGFloat(min(max(b["gap"]?.number ?? 2, 0), 12))
        let barWidth = max((size.width - gap * CGFloat(values.count - 1)) / CGFloat(max(values.count, 1)), 0)
        let base = min(max(0, range.0), range.1)
        let y = { (v: Double) in size.height * CGFloat(1 - (v - range.0) / (range.1 - range.0)) }
        let round = b["round"] == .bool(true), centered = b["base"]?.string == "center"
        return ForEach(Array(values.enumerated()), id: \.offset) { i, v in
            let height = centered ? min(max(size.height - y(v), 0), size.height) : abs(y(v) - y(base))
            let top = centered ? (size.height - height) / 2 : min(y(v), y(base))
            LiveCorners(radii: Array(repeating: round ? barWidth / 2 : 0, count: 4))
                .fill(color(i))
                .frame(width: barWidth, height: height)
                .offset(x: CGFloat(i) * (barWidth + gap), y: top)
        }
    }

    /// Straight lines through `points`; closed down to `closedTo` for an area.
    static func polyline(_ points: [CGPoint], closedTo bottom: CGFloat?) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        points.dropFirst().forEach { p.addLine(to: $0) }
        if let bottom, let last = points.last {
            p.addLine(to: CGPoint(x: last.x, y: bottom))
            p.addLine(to: CGPoint(x: first.x, y: bottom))
            p.closeSubpath()
        }
        return p
    }
}
#endif
