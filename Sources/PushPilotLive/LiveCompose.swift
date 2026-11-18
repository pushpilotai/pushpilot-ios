#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI

@available(iOS 16.1, *)
extension PushPilotLiveBlock {
    /// A `use`: the named drawing from `defs`, once (scaled evenly to fit a sized box) or once per copy.
    @ViewBuilder
    func use(_ b: LiveJSON, fill: LiveFill, depth: Int) -> some View {
        if let name = b["ref"]?.string, let def = defs?[name] {
            let defSize = Self.ownSize(def)
            let inner = inside(def, colors: b["colors"])
            if let copies = b["copies"]?.items, !copies.isEmpty {
                let view = Self.viewSize(b["view"]) ?? viewBox ?? CGSize(width: 100, height: 100)
                // shortcut: a def with no size of its own is drawn 24 points square per copy; the contract gives it none.
                let own = defSize ?? CGSize(width: 24, height: 24)
                GeometryReader { g in
                    let frames = LiveGeometry.copyFrames(copies.map { $0.items.compactMap(\.number) }, view: view, box: g.size, defSize: own)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                            inner.draw(def, depth: depth + 1)
                                .frame(width: own.width, height: own.height)
                                .scaleEffect(frame.width / max(own.width, 0.01))
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            } else if let defSize, b["w"] != nil || b["h"] != nil || fill.width || fill.height {
                GeometryReader { g in
                    inner.draw(def, depth: depth + 1)
                        .scaleEffect(min(g.size.width / max(defSize.width, 0.01), g.size.height / max(defSize.height, 0.01)))
                        .frame(width: g.size.width, height: g.size.height)
                }
            } else {
                // Only a drawing takes the space offered; a text def keeps its natural size, a def's own w or h stays.
                let drawing = isDrawing(def, depth: depth)
                // The stack keeps the def root's at, pos and fractions inside, so the use's own (see `placed`) place it.
                ZStack {
                    inner.draw(def, LiveFill(width: fill.width || drawing && def["w"] == nil, height: fill.height || drawing && def["h"] == nil), depth: depth + 1)
                }
            }
        }
    }

    /// A `use` given its def root's `at`, `pos`, `fw` and `fh` where it has none of its own, since the use's box
    /// is what its parent places; any other block unchanged.
    func placed(_ b: LiveJSON) -> LiveJSON {
        guard b["type"]?.string == "use", case .object(var o) = b, (b["copies"]?.items ?? []).isEmpty,
              let def = b["ref"]?.string.flatMap({ defs?[$0] }) else { return b }
        for key in ["at", "pos", "fw", "fh"] where o[key] == nil { o[key] = def[key] }
        return .object(o)
    }

    /// Whether a block is a drawing that takes the space offered: a shape, arc, path, chart or grid, or a
    /// container or use holding one.
    func isDrawing(_ b: LiveJSON, depth: Int = 0) -> Bool {
        guard depth < 24 else { return false }
        switch b["type"]?.string {
        case "shape", "arc", "path", "chart", "grid": return true
        case "row", "column", "layer": return b["items"]?.items.contains { isDrawing($0, depth: depth + 1) } ?? false
        case "use": return b["ref"]?.string.flatMap { defs?[$0] }.map { isDrawing($0, depth: depth + 1) } ?? false
        default: return false
        }
    }

    /// The drawer for a def: its own `view` (nothing inherited from outside), and the `use`'s `colors`
    /// over the enclosing def's, a `$name` value taken from the enclosing def's colours.
    func inside(_ def: LiveJSON, colors: LiveJSON?) -> PushPilotLiveBlock {
        var palette = self.palette
        if case .object(let given)? = colors {
            for key in given.keys.sorted().prefix(8) {
                guard let value = given[key]?.string else { continue }
                palette[key] = value.hasPrefix("$") ? self.palette[String(value.dropFirst())] ?? "primary" : value
            }
        }
        return with {
            $0.palette = palette
            $0.viewBox = Self.viewSize(def["view"])
        }
    }

    /// A block's own `w` and `h`, when it has both.
    static func ownSize(_ b: LiveJSON) -> CGSize? {
        guard let w = b["w"]?.number, let h = b["h"]?.number else { return nil }
        return CGSize(width: w, height: h)
    }

    /// A `grid`: `count` cells in `cols` columns, filled cells (the first or, `from: end`, last `filled`, or
    /// those a numbers list marks) drawing `tile` and the others `empty`, the `current` cell `current_tile`;
    /// each block fills its cell and shows the cell's `labels` entry as `{{label}}`.
    func grid(_ b: LiveJSON, depth: Int) -> some View {
        let cols = Int(min(max(b["cols"]?.number ?? 1, 1), 24)), count = Int(min(max(b["count"]?.number ?? 1, 1), 96))
        let filled = content.gridFilled(b["filled"], count: count, fromEnd: b["from"]?.string == "end")
        let current = b["current_tile"] == nil ? nil : content.value(b["current"]).map { Int(min(max($0.rounded(), -1), 96)) }
        let labels = b["labels"] == nil ? nil : content.labels(b["labels"], limit: count)
        let cell = LiveFill(width: true, height: true)
        return LiveGridLayout(cols: cols, rows: (count + cols - 1) / cols, gap: CGFloat(min(max(b["gap"]?.number ?? 0, 0), 24)), square: b["h"] == nil) {
            ForEach(0..<count, id: \.self) { i in
                if let block = i == current ? b["current_tile"] : filled[i] ? b["tile"] : b["empty"] {
                    let drawer = labels.map { l in with { $0.content.label = l.indices.contains(i) ? l[i] : "" } } ?? self
                    drawer.draw(block, cell, depth: depth + 1)
                } else {
                    Color.clear
                }
            }
        }
    }

    /// A bar at the field's value with its `segments`, `points` and `tracker`, or running by itself between
    /// two times.
    @ViewBuilder
    func progress(_ b: LiveJSON) -> some View {
        let tint = color(b["color"]?.string ?? "accent") ?? .accentColor
        if let from = content.date(b["from"]?.string), let to = content.date(b["to"]?.string), to > from {
            // shortcut: a bar that runs by itself is the system's, without segments, points or tracker; iOS cannot animate a custom one.
            ProgressView(timerInterval: from...to, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }.tint(tint)
        } else {
            let value = content.fraction(b)
            let segments = Int(min(max(b["segments"]?.number ?? 1, 1), 10))
            let points = (b["points"]?.items ?? []).compactMap(\.number).prefix(5)
            let tracker = b["tracker"]?.string.flatMap { PushPilotLiveIcons.symbols[$0] }
            GeometryReader { g in
                let y = g.size.height / 2, w = g.size.width
                let bar = HStack(spacing: 3) { ForEach(0..<segments, id: \.self) { _ in Capsule() } }.frame(height: 6)
                ZStack(alignment: .leading) {
                    bar.foregroundColor(tint.opacity(0.25))
                    bar.foregroundColor(tint).mask(alignment: .leading) { Rectangle().frame(width: w * CGFloat(value)) }
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        Circle().fill(p <= value ? tint : Color(white: 0.6)).frame(width: 10, height: 10)
                            .position(x: min(max(w * CGFloat(p), 5), w - 5), y: y)
                    }
                    if let tracker {
                        Image(systemName: tracker).font(.system(size: 13, weight: .bold)).foregroundColor(tint)
                            .padding(3).background(Circle().fill(Color(white: 1)))
                            .position(x: min(max(w * CGFloat(value), 10), w - 10), y: y)
                    }
                }
            }
            .frame(height: tracker == nil && points.isEmpty ? 6 : 22)
        }
    }
}
#endif
