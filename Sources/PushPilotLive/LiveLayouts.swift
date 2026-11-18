#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI

/// A block's `fw` and `fh` (0 to 1), read by its parent to give it that share of the parent's size.
struct LiveFractionKey: LayoutValueKey {
    static let defaultValue: CGSize? = nil
}

/// A block's `at`, read by a `layer` to place it.
struct LiveAtKey: LayoutValueKey {
    static let defaultValue: Alignment = .center
}

/// Marks a `spacer`, which rows and columns give the space left after every other item.
/// A layer item's `pos`: where its centre sits as a fraction of the layer's size, instead of `at`.
struct LivePosKey: LayoutValueKey {
    static let defaultValue: CGPoint? = nil
}

struct LiveSpacerKey: LayoutValueKey {
    static let defaultValue = false
}

/// A finite length, or nil for an unspecified or infinite one.
private func finite(_ value: CGFloat?) -> CGFloat? {
    guard let value, value.isFinite else { return nil }
    return value
}

/// A `row` (horizontal) or `column`: items one after another with `spacing` (negative overlaps), each
/// given its `fw`/`fh` share first, then the others by flexibility like a SwiftUI stack, spacers last.
/// `fillMain`/`fillCross` make it take the whole proposed length, so items' fractions have a size to be
/// a fraction of.
@available(iOS 16.1, *)
struct LiveStackLayout: Layout {
    var horizontal: Bool
    var spacing: CGFloat
    /// `top`, `center`, `bottom` or `baseline` for a row; `leading`, `center` or `trailing` for a column.
    var align: String?
    var fillMain: Bool
    var fillCross: Bool

    /// The stack's size for a proposal.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (sizes, proposals) = measure(proposal, subviews)
        var length = sizes.reduce(0) { $0 + main($1) } + spacing * CGFloat(max(subviews.count - 1, 0))
        var thickness = baseline ? baselineExtent(sizes, proposals, subviews).total : sizes.map(cross).max() ?? 0
        if fillMain, let p = finite(main(proposal)) { length = p }
        if fillCross, let p = finite(cross(proposal)) { thickness = p }
        return make(max(length, 0), thickness)
    }

    /// Places the items along the main axis and by `align` across it.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The same proposal as sizeThatFits, so each item gets the size it was measured at (text never loses a rounding sliver).
        let (sizes, proposals) = measure(proposal, subviews)
        let extent = baseline ? baselineExtent(sizes, proposals, subviews) : (above: 0, total: 0)
        var along = horizontal ? bounds.minX : bounds.minY
        let crossStart = horizontal ? bounds.minY : bounds.minX
        let crossLength = horizontal ? bounds.height : bounds.width
        for (i, view) in subviews.enumerated() {
            let size = sizes[i]
            let offset: CGFloat
            if baseline {
                let line = view.dimensions(in: proposals[i])[VerticalAlignment.firstTextBaseline]
                offset = (crossLength - extent.total) / 2 + extent.above - line
            } else {
                switch align {
                case "top"?, "leading"?: offset = 0
                case "bottom"?, "trailing"?: offset = crossLength - cross(size)
                case "center"?: offset = (crossLength - cross(size)) / 2
                default: offset = horizontal ? (crossLength - cross(size)) / 2 : 0
                }
            }
            let point = horizontal ? CGPoint(x: along, y: crossStart + offset) : CGPoint(x: crossStart + offset, y: along)
            view.place(at: point, anchor: .topLeading, proposal: proposals[i])
            along += main(size) + spacing
        }
    }

    private var baseline: Bool { horizontal && align == "baseline" }

    /// The height above the shared baseline and the total height of a baseline row.
    private func baselineExtent(_ sizes: [CGSize], _ proposals: [ProposedViewSize], _ subviews: Subviews) -> (above: CGFloat, total: CGFloat) {
        var above: CGFloat = 0, below: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let line = view.dimensions(in: proposals[i])[VerticalAlignment.firstTextBaseline]
            above = max(above, line)
            below = max(below, sizes[i].height - line)
        }
        return (above, above + below)
    }

    /// Every item's size: fractions first, then the rest from least to most flexible sharing what is left,
    /// then spacers splitting the remainder. Each item is later placed with the proposal it was measured with,
    /// not its exact size, so a text proposed its own width never truncates over a rounding sliver.
    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (sizes: [CGSize], proposals: [ProposedViewSize]) {
        let total = finite(main(proposal))
        let crossProposal = cross(proposal)
        var sizes = Array(repeating: CGSize.zero, count: subviews.count)
        var proposals = Array(repeating: ProposedViewSize.zero, count: subviews.count)
        var left = total.map { $0 - spacing * CGFloat(max(subviews.count - 1, 0)) }
        var others: [Int] = [], spacers: [Int] = []
        /// The cross-axis proposal for one item: its cross fraction of the stack's, or the stack's.
        func crossFor(_ i: Int) -> CGFloat? {
            guard let f = subviews[i][LiveFractionKey.self], let c = finite(crossProposal) else { return crossProposal }
            let share = horizontal ? f.height : f.width
            return share >= 0 ? c * share : crossProposal
        }
        for i in subviews.indices {
            if subviews[i][LiveSpacerKey.self] { spacers.append(i); continue }
            if let f = subviews[i][LiveFractionKey.self], let t = total, (horizontal ? f.width : f.height) >= 0 {
                let share = t * (horizontal ? f.width : f.height)
                proposals[i] = make(share, crossFor(i))
                sizes[i] = subviews[i].sizeThatFits(proposals[i])
                left = left.map { $0 - main(sizes[i]) }
            } else {
                others.append(i)
            }
        }
        // Each item's own length (unbounded) and least length, when there is a length to share.
        var ideal: [CGFloat] = Array(repeating: 0, count: subviews.count), least = ideal
        if left != nil {
            for i in others {
                ideal[i] = main(subviews[i].sizeThatFits(make(.infinity, crossFor(i))))
                least[i] = main(subviews[i].sizeThatFits(make(0, crossFor(i))))
            }
            others.sort { ideal[$0] - least[$0] < ideal[$1] - least[$1] }
        }
        for (n, i) in others.enumerated() {
            let rest = others[(n + 1)...].reduce(0) { $0 + least[$1] }
            // An item whose own length fits beside the others' least gets it (a two-line text before a drawing), else an
            // equal share; a quarter point of slack, as what is left can fall a rounding hair short of a text's own length.
            let share = left.map { max($0 / CGFloat(others.count - n), ideal[i] < $0 ? min(ideal[i], $0 - rest) : 0, 0) + 0.25 }
            proposals[i] = make(share, crossFor(i))
            sizes[i] = subviews[i].sizeThatFits(proposals[i])
            left = left.map { $0 - main(sizes[i]) }
        }
        for (n, i) in spacers.enumerated() {
            let share = max((left ?? 0) / CGFloat(spacers.count - n), 0)
            sizes[i] = make(share, 0)
            proposals[i] = ProposedViewSize(sizes[i])
            left = left.map { $0 - share }
        }
        return (sizes, proposals)
    }

    private func main(_ s: CGSize) -> CGFloat { horizontal ? s.width : s.height }
    private func cross(_ s: CGSize) -> CGFloat { horizontal ? s.height : s.width }
    private func main(_ p: ProposedViewSize) -> CGFloat? { horizontal ? p.width : p.height }
    private func cross(_ p: ProposedViewSize) -> CGFloat? { horizontal ? p.height : p.width }
    private func make(_ m: CGFloat, _ c: CGFloat) -> CGSize { horizontal ? CGSize(width: m, height: c) : CGSize(width: c, height: m) }
    private func make(_ m: CGFloat?, _ c: CGFloat?) -> ProposedViewSize {
        horizontal ? ProposedViewSize(width: m, height: c) : ProposedViewSize(width: c, height: m)
    }
}

/// A `layer`: items drawn on top of each other, each placed by its `at`. Its size is its largest item,
/// or the whole proposal along an axis it fills (`w`/`h`, a fraction, or an item's fraction).
@available(iOS 16.1, *)
struct LiveLayerLayout: Layout {
    var fillWidth: Bool
    var fillHeight: Bool

    /// The layer's size for a proposal.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var size = CGSize.zero
        for view in subviews where !view[LiveSpacerKey.self] {
            let s = view.sizeThatFits(childProposal(view, proposal))
            size.width = max(size.width, s.width)
            size.height = max(size.height, s.height)
        }
        if fillWidth, let w = finite(proposal.width) { size.width = w }
        if fillHeight, let h = finite(proposal.height) { size.height = h }
        return size
    }

    /// Places each item at its `pos`, else its `at`, inside the layer.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let p = childProposal(view, ProposedViewSize(width: bounds.width, height: bounds.height))
            if let pos = view[LivePosKey.self] {
                view.place(at: CGPoint(x: bounds.minX + bounds.width * pos.x, y: bounds.minY + bounds.height * pos.y), anchor: .center, proposal: p)
                continue
            }
            let at = view[LiveAtKey.self]
            let unit = UnitPoint(x: at.horizontal == .leading ? 0 : at.horizontal == .trailing ? 1 : 0.5,
                                 y: at.vertical == .top ? 0 : at.vertical == .bottom ? 1 : 0.5)
            view.place(at: CGPoint(x: bounds.minX + bounds.width * unit.x, y: bounds.minY + bounds.height * unit.y), anchor: unit, proposal: p)
        }
    }

    /// An item's proposal: its fractions of the layer's size, else the layer's own proposal.
    private func childProposal(_ view: LayoutSubview, _ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let f = view[LiveFractionKey.self] else { return proposal }
        return ProposedViewSize(width: f.width >= 0 ? finite(proposal.width).map { $0 * f.width } ?? proposal.width : proposal.width,
                                height: f.height >= 0 ? finite(proposal.height).map { $0 * f.height } ?? proposal.height : proposal.height)
    }
}

/// A `grid`: `cols` columns sharing the width, cells square unless the grid has a height to share.
@available(iOS 16.1, *)
struct LiveGridLayout: Layout {
    var cols: Int
    var rows: Int
    var gap: CGFloat
    var square: Bool

    /// The grid's size: the proposed width (or 24 points a column), and square rows or the proposed height.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = finite(proposal.width) ?? CGFloat(cols) * 24 + gap * CGFloat(cols - 1)
        let cell = LiveGeometry.gridCell(width: width, height: square ? nil : finite(proposal.height), cols: cols, rows: rows, gap: gap)
        return CGSize(width: width, height: cell.height * CGFloat(rows) + gap * CGFloat(rows - 1))
    }

    /// Puts item `i` in column `i % cols`, row `i / cols`, offered the cell's size and centred in it (a tile
    /// with its own `w`/`h` is smaller than its cell).
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = LiveGeometry.gridCell(width: bounds.width, height: square ? nil : bounds.height, cols: cols, rows: rows, gap: gap)
        for (i, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % cols) * (cell.width + gap), y = bounds.minY + CGFloat(i / cols) * (cell.height + gap)
            view.place(at: CGPoint(x: x + cell.width / 2, y: y + cell.height / 2), anchor: .center, proposal: ProposedViewSize(cell))
        }
    }
}
#endif
