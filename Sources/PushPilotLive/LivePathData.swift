import CoreGraphics
import Foundation

/// One step of a parsed `path` block, in absolute view-box coordinates.
public enum LivePathSegment: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    /// A quadratic curve: control point, end point.
    case quad(CGPoint, CGPoint)
    /// A cubic curve: first control, second control, end point.
    case cubic(CGPoint, CGPoint, CGPoint)
    case close
}

/// Reads the path text of a `path` block: SVG commands `M L H V C S Q T A Z`, upper case absolute and
/// lower case relative (LIVE.md "Contract version 2" and "Round two"). Arcs become cubic curves.
public enum LivePathParser {
    /// The segments of `d`, or nil when it holds anything the contract does not allow (a stray letter, a
    /// missing number or flag), so a bad path draws nothing rather than something wrong.
    public static func parse(_ d: String) -> [LivePathSegment]? {
        var reader = NumberReader(Array(d.utf8))
        var out: [LivePathSegment] = []
        var current = CGPoint.zero, start = CGPoint.zero
        var cubicControl: CGPoint?, quadControl: CGPoint?
        var command: UInt8?
        while true {
            reader.skipSeparators()
            guard let byte = reader.peek else { break }
            if isLetter(byte) {
                guard commands.contains(byte | 0x20) else { return nil }
                command = byte
                reader.index += 1
                if byte | 0x20 == UInt8(ascii: "z") {
                    out.append(.close)
                    current = start
                    cubicControl = nil
                    quadControl = nil
                    continue
                }
            } else if command == nil || command.map({ $0 | 0x20 == UInt8(ascii: "z") }) == true {
                return nil
            }
            guard let c = command else { return nil }
            let relative = c >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            /// A point read from the text, relative to `base` for lower-case commands.
            func point() -> CGPoint? {
                guard let x = reader.number(), let y = reader.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var cubic: CGPoint?, quad: CGPoint?
            switch c | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return nil }
                out.append(.move(p))
                current = p
                start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // later pairs are lines
            case UInt8(ascii: "l"):
                guard let p = point() else { return nil }
                out.append(.line(p))
                current = p
            case UInt8(ascii: "h"):
                guard let x = reader.number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                out.append(.line(current))
            case UInt8(ascii: "v"):
                guard let y = reader.number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                out.append(.line(current))
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                out.append(.cubic(c1, c2, p))
                current = p
                cubic = c2
            case UInt8(ascii: "s"):
                let c1 = cubicControl.map { reflect($0, about: current) } ?? current
                guard let c2 = point(), let p = point() else { return nil }
                out.append(.cubic(c1, c2, p))
                current = p
                cubic = c2
            case UInt8(ascii: "q"):
                guard let q = point(), let p = point() else { return nil }
                out.append(.quad(q, p))
                current = p
                quad = q
            case UInt8(ascii: "t"):
                let q = quadControl.map { reflect($0, about: current) } ?? current
                guard let p = point() else { return nil }
                out.append(.quad(q, p))
                current = p
                quad = q
            case UInt8(ascii: "a"):
                guard let rx = reader.number(), let ry = reader.number(), let turn = reader.number(),
                      let large = reader.flag(), let sweep = reader.flag(), let p = point() else { return nil }
                out += arc(from: current, rx: rx, ry: ry, rotation: turn, large: large, sweep: sweep, to: p)
                current = p
            default:
                return nil
            }
            cubicControl = cubic
            quadControl = quad
        }
        return out
    }

    private static let commands = Set("mlhvcsqtaz".utf8)

    /// Whether a byte is an ASCII letter other than the exponent `e`, which belongs to a number.
    private static func isLetter(_ b: UInt8) -> Bool {
        let lower = b | 0x20
        return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z") && lower != UInt8(ascii: "e")
    }

    /// An SVG elliptical arc as cubic curves of at most 90 degrees each (SVG 1.1 appendix F.6.5 and F.6.6):
    /// a line when a radius is 0, nothing when the end is the start, radii grown when too small to reach.
    static func arc(from p0: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool, to p: CGPoint) -> [LivePathSegment] {
        if p0 == p { return [] }
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 { return [.line(p)] }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (large == sweep ? -1 : 1) * (den > 0 ? max(num / den, 0).squareRoot() : 0)
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p.x) / 2, cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p.y) / 2
        let theta = atan2((y1 - cyp) / ry, (x1 - cxp) / rx)
        var delta = atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx) - theta
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        let count = max(Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)), 1)
        let step = delta / CGFloat(count), k = 4 / 3 * tan(step / 4)
        /// A point of the unit circle's frame mapped onto the ellipse.
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        return (0..<count).map { i in
            let a = theta + CGFloat(i) * step, b = a + step
            let end = i == count - 1 ? p : map(cos(b), sin(b))
            return .cubic(map(cos(a) - k * sin(a), sin(a) + k * cos(a)), map(cos(b) + k * sin(b), sin(b) - k * cos(b)), end)
        }
    }

    /// `p` mirrored through `center`: the implied control point of `S` and `T`.
    private static func reflect(_ p: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - p.x, y: 2 * center.y - p.y)
    }
}

/// Reads SVG numbers: `-5`, `.1`, `1.5.5` (two numbers), `10-5` (two numbers), `1e-3`.
private struct NumberReader {
    let bytes: [UInt8]
    var index = 0

    /// A reader over the path text's bytes.
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The next byte, or nil at the end.
    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    /// Skips spaces, commas and line breaks.
    mutating func skipSeparators() {
        while let b = peek, b == 0x20 || b == 0x2C || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
    }

    /// An arc flag: one `0` or `1`, which may touch the next flag or number (`0110`).
    mutating func flag() -> Bool? {
        skipSeparators()
        guard let b = peek, b == UInt8(ascii: "0") || b == UInt8(ascii: "1") else { return nil }
        index += 1
        return b == UInt8(ascii: "1")
    }

    /// The next number, or nil when there is none.
    mutating func number() -> CGFloat? {
        skipSeparators()
        let begin = index
        if let b = peek, b == UInt8(ascii: "-") || b == UInt8(ascii: "+") { index += 1 }
        var digits = 0, dot = false
        while let b = peek {
            if b >= 0x30 && b <= 0x39 { digits += 1 } else if b == UInt8(ascii: "."), !dot { dot = true } else { break }
            index += 1
        }
        guard digits > 0 else { index = begin; return nil }
        if let b = peek, b | 0x20 == UInt8(ascii: "e") {
            var probe = index + 1
            if probe < bytes.count, bytes[probe] == UInt8(ascii: "-") || bytes[probe] == UInt8(ascii: "+") { probe += 1 }
            if probe < bytes.count, bytes[probe] >= 0x30 && bytes[probe] <= 0x39 {
                index = probe
                while let d = peek, d >= 0x30 && d <= 0x39 { index += 1 }
            }
        }
        return String(bytes: bytes[begin..<index], encoding: .ascii).flatMap(Double.init).map { CGFloat($0) }
    }
}

/// Lengths along a parsed path, for `trim` and `marker`.
public enum LivePathGeometry {
    /// The path as straight pieces: each sub-path a list of points, curves cut into 24 steps.
    public static func polylines(_ segments: [LivePathSegment], transform: CGAffineTransform = .identity) -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        var current = CGPoint.zero, start = CGPoint.zero
        /// Adds a point to the open sub-path, starting one at `current` when needed.
        func add(_ p: CGPoint) {
            if lines.isEmpty { lines.append([current.applying(transform)]) }
            lines[lines.count - 1].append(p.applying(transform))
        }
        for segment in segments {
            switch segment {
            case .move(let p):
                lines.append([p.applying(transform)])
                current = p
                start = p
            case .line(let p):
                add(p)
                current = p
            case .quad(let c, let p):
                let p0 = current
                for i in 1...24 {
                    let t = CGFloat(i) / 24, u = 1 - t
                    add(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p.y))
                }
                current = p
            case .cubic(let c1, let c2, let p):
                let p0 = current
                for i in 1...24 {
                    let t = CGFloat(i) / 24, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    add(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p.x, y: a * p0.y + b * c1.y + c * c2.y + d * p.y))
                }
                current = p
            case .close:
                add(start)
                current = start
            }
        }
        return lines
    }

    /// The point `fraction` (0 to 1) of the way along the whole path, or nil for an empty path.
    public static func point(at fraction: Double, in lines: [[CGPoint]]) -> CGPoint? {
        let pieces = lines.flatMap { line in zip(line, line.dropFirst()).map { ($0, $1) } }
        guard let first = lines.first?.first else { return nil }
        let total = pieces.reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard total > 0 else { return first }
        var left = CGFloat(min(max(fraction, 0), 1)) * total
        for (a, b) in pieces {
            let length = hypot(b.x - a.x, b.y - a.y)
            if left <= length, length > 0 {
                let t = left / length
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            left -= length
        }
        return pieces.last?.1 ?? first
    }

    /// How a `view` box maps onto a block's box for `fit` `fill` (stretch), `contain` or `cover` (even
    /// scale, centred). Returns the transform and the even scale used for stroke widths.
    public static func fit(view: CGSize, into box: CGRect, fit: String?) -> (CGAffineTransform, CGFloat) {
        guard view.width > 0, view.height > 0 else { return (.identity, 1) }
        var sx = box.width / view.width, sy = box.height / view.height
        if fit == "contain" || fit == "cover" {
            let s = fit == "contain" ? min(sx, sy) : max(sx, sy)
            sx = s
            sy = s
        }
        let dx = box.minX + (box.width - view.width * sx) / 2, dy = box.minY + (box.height - view.height * sy) / 2
        return (CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: dx, ty: dy), min(sx, sy))
    }
}
