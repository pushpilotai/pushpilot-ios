import CoreGraphics
import Foundation

/// One drawn piece of an `arc`: angles in degrees (0 at 12 o'clock, clockwise) and how far it is filled.
public struct LiveArcPiece: Equatable {
    public let start: Double
    public let end: Double
    /// Where the filled part ends; equal to `start` when nothing of this piece is filled.
    public let filledEnd: Double
    /// The piece's number, for `colors`.
    public let index: Int
}

/// The pure arithmetic behind `arc`, `grid`, `use` copies and `chart`, shared by the views and the tests.
public enum LiveGeometry {
    /// The pieces of an arc of `sweep` degrees from `start`, cut into `segments` with `gap` degrees between
    /// them (a full ring has a gap after every segment, a partial one only between them), filled to `value`
    /// of the drawn length.
    public static func arcPieces(start: Double, sweep: Double, segments: Int, gap: Double, value: Double) -> [LiveArcPiece] {
        let count = max(segments, 1)
        let sweep = min(max(sweep, 0), 360)
        let gaps = count == 1 ? 0 : sweep >= 360 ? count : count - 1
        let length = max((sweep - Double(gaps) * gap) / Double(count), 0)
        var filled = min(max(value, 0), 1) * length * Double(count)
        return (0..<count).map { i in
            let from = start + Double(i) * (length + gap)
            let part = min(max(filled, 0), length)
            filled -= length
            return LiveArcPiece(start: from, end: from + length, filledEnd: from + part, index: i)
        }
    }

    /// Whether cell `index` of a grid of `count` cells is filled when `filled` tiles are, counted from the
    /// start or, with `fromEnd`, from the end.
    public static func gridCellFilled(_ index: Int, count: Int, filled: Double, fromEnd: Bool) -> Bool {
        let n = Int(min(max(filled.rounded(), 0), Double(count)))
        return fromEnd ? index >= count - n : index < n
    }

    /// The size of one grid cell: columns share the width; cells are square unless `height` is given,
    /// when the rows share it too.
    public static func gridCell(width: CGFloat, height: CGFloat?, cols: Int, rows: Int, gap: CGFloat) -> CGSize {
        let w = max((width - gap * CGFloat(cols - 1)) / CGFloat(max(cols, 1)), 0)
        guard let height else { return CGSize(width: w, height: w) }
        return CGSize(width: w, height: max((height - gap * CGFloat(rows - 1)) / CGFloat(max(rows, 1)), 0))
    }

    /// Where each copy of a `use` is drawn: the `view` box scaled evenly to fit `box` and centred, each
    /// copy centred on its point at the def's own size times its scale (0.1 to 4) times that same factor.
    public static func copyFrames(_ copies: [[Double]], view: CGSize, box: CGSize, defSize: CGSize) -> [CGRect] {
        guard view.width > 0, view.height > 0 else { return [] }
        let k = min(box.width / view.width, box.height / view.height)
        let ox = (box.width - view.width * k) / 2, oy = (box.height - view.height * k) / 2
        return copies.compactMap { c in
            guard c.count >= 2 else { return nil }
            let s = CGFloat(c.count > 2 ? min(max(c[2], 0.1), 4) : 1) * k
            let size = CGSize(width: defSize.width * s, height: defSize.height * s)
            return CGRect(x: ox + CGFloat(c[0]) * k - size.width / 2, y: oy + CGFloat(c[1]) * k - size.height / 2,
                          width: size.width, height: size.height)
        }
    }

    /// The bottom and top of a chart's scale: `min` and `max` when given, else the values' range, with bars
    /// always reaching 0.
    public static func chartRange(_ values: [Double], min low: Double?, max high: Double?, bars: Bool) -> (Double, Double) {
        var lo = low ?? (values.min() ?? 0), hi = high ?? (values.max() ?? 1)
        if bars, low == nil { lo = Swift.min(lo, 0) }
        if bars, high == nil { hi = Swift.max(hi, 0) }
        return hi > lo ? (lo, hi) : (lo, lo + 1)
    }

    /// The points of a line chart in a box: first value at the leading edge, last at the trailing edge.
    public static func chartPoints(_ values: [Double], range: (Double, Double), size: CGSize) -> [CGPoint] {
        let span = range.1 - range.0
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { i, v in
            let t = min(max((v - range.0) / span, 0), 1)
            return CGPoint(x: CGFloat(i) * step, y: size.height * CGFloat(1 - t))
        }
    }
}
