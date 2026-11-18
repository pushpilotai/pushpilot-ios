import SwiftUI
import XCTest
@testable import PushPilotLive

/// Layout contract version 2 (LIVE.md "Contract version 2: drawing pieces"): the pure parts of the renderer.
@available(iOS 16.1, *)
final class LiveDrawingTests: XCTestCase {
    /// Shorthand for a point.
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// Every command in its absolute form.
    func testPathAbsoluteCommands() {
        XCTAssertEqual(LivePathParser.parse("M10 20L30 40H50V60Z"), [.move(p(10, 20)), .line(p(30, 40)), .line(p(50, 40)), .line(p(50, 60)), .close])
        XCTAssertEqual(LivePathParser.parse("M0 0C0 10 10 10 10 0S20 -10 20 0"),
                       [.move(p(0, 0)), .cubic(p(0, 10), p(10, 10), p(10, 0)), .cubic(p(10, -10), p(20, -10), p(20, 0))])
        XCTAssertEqual(LivePathParser.parse("M0 0Q5 10 10 0T20 0"), [.move(p(0, 0)), .quad(p(5, 10), p(10, 0)), .quad(p(15, -10), p(20, 0))])
        // S and T after another kind of command take the current point as their first control.
        XCTAssertEqual(LivePathParser.parse("M0 0L5 5S10 10 15 5T20 0"),
                       [.move(p(0, 0)), .line(p(5, 5)), .cubic(p(5, 5), p(10, 10), p(15, 5)), .quad(p(15, 5), p(20, 0))])
    }

    /// Lower-case commands are relative to the current point, and `z` returns it to the sub-path's start.
    func testPathRelativeCommands() {
        XCTAssertEqual(LivePathParser.parse("m10 20l5 5h10v-5z"), [.move(p(10, 20)), .line(p(15, 25)), .line(p(25, 25)), .line(p(25, 20)), .close])
        XCTAssertEqual(LivePathParser.parse("M10 10c0 10 10 10 10 0s10 -10 10 0"),
                       [.move(p(10, 10)), .cubic(p(10, 20), p(20, 20), p(20, 10)), .cubic(p(20, 0), p(30, 0), p(30, 10))])
        XCTAssertEqual(LivePathParser.parse("M10 10q5 10 10 0t10 0"), [.move(p(10, 10)), .quad(p(15, 20), p(20, 10)), .quad(p(25, 0), p(30, 10))])
        XCTAssertEqual(LivePathParser.parse("M10 10l5 0z l5 0"), [.move(p(10, 10)), .line(p(15, 10)), .close, .line(p(15, 10))])
        // Pairs after a move are lines, relative after a relative move.
        XCTAssertEqual(LivePathParser.parse("M0 0 10 0"), [.move(p(0, 0)), .line(p(10, 0))])
        XCTAssertEqual(LivePathParser.parse("m1 1 2 2"), [.move(p(1, 1)), .line(p(3, 3))])
    }

    /// SVG's compact number forms.
    func testPathNumbers() {
        XCTAssertEqual(LivePathParser.parse("M50 13h.1"), [.move(p(50, 13)), .line(p(50.1, 13))])
        XCTAssertEqual(LivePathParser.parse("M1.5.5"), [.move(p(1.5, 0.5))])
        XCTAssertEqual(LivePathParser.parse("M10-5,1e1 2"), [.move(p(10, -5)), .line(p(10, 2))])
        XCTAssertEqual(LivePathParser.parse(""), [])
    }

    /// Anything outside the contract is refused whole, so it draws nothing.
    func testPathBadInput() {
        XCTAssertNil(LivePathParser.parse("M0 0A5 5 0 2 1 10 0"), "an arc flag must be 0 or 1")
        XCTAssertNil(LivePathParser.parse("M0 0L10"), "a missing number")
        XCTAssertNil(LivePathParser.parse("10 10"), "a number before any command")
        XCTAssertNil(LivePathParser.parse("M0 0Z 5 5"), "numbers after Z")
        XCTAssertNil(LivePathParser.parse("M0 0 X1 1"), "an unknown letter")
        XCTAssertNil(LivePathParser.parse("M0 0C1 1 2 2"), "a curve without its end")
    }

    /// Points along a path for `marker`, across curves and sub-paths, and the `view` fits.
    func testPathLengthsAndFit() throws {
        let lines = LivePathGeometry.polylines(try XCTUnwrap(LivePathParser.parse("M0 0L10 0L10 10")))
        XCTAssertEqual(LivePathGeometry.point(at: 0.25, in: lines), p(5, 0))
        XCTAssertEqual(LivePathGeometry.point(at: 0.5, in: lines), p(10, 0))
        XCTAssertEqual(LivePathGeometry.point(at: 1, in: lines), p(10, 10))
        XCTAssertEqual(LivePathGeometry.point(at: 3, in: lines), p(10, 10), "fractions are clamped")
        let curve = LivePathGeometry.polylines(try XCTUnwrap(LivePathParser.parse("M0 0Q50 0 100 0")))
        let mid = try XCTUnwrap(LivePathGeometry.point(at: 0.5, in: curve))
        XCTAssertEqual(mid.x, 50, accuracy: 0.5)
        let (stretch, s1) = LivePathGeometry.fit(view: CGSize(width: 100, height: 100), into: CGRect(x: 0, y: 0, width: 200, height: 50), fit: nil)
        XCTAssertEqual(p(100, 100).applying(stretch), p(200, 50))
        XCTAssertEqual(s1, 0.5)
        let (contain, s2) = LivePathGeometry.fit(view: CGSize(width: 100, height: 100), into: CGRect(x: 0, y: 0, width: 200, height: 50), fit: "contain")
        XCTAssertEqual(p(0, 0).applying(contain), p(75, 0))
        XCTAssertEqual(s2, 0.5)
        let (cover, _) = LivePathGeometry.fit(view: CGSize(width: 100, height: 100), into: CGRect(x: 0, y: 0, width: 200, height: 50), fit: "cover")
        XCTAssertEqual(p(0, 0).applying(cover), p(0, -75))
    }

    /// Segments share the sweep less the gaps (a ring has a gap after each), and the value fills the drawn length.
    func testArcSegments() {
        let ring = LiveGeometry.arcPieces(start: 0, sweep: 360, segments: 6, gap: 7, value: 0.5)
        XCTAssertEqual(ring.count, 6)
        XCTAssertEqual(ring[0], LiveArcPiece(start: 0, end: 53, filledEnd: 53, index: 0))
        XCTAssertEqual(ring[1].start, 60)
        XCTAssertEqual(ring[2].filledEnd, ring[2].end)
        XCTAssertEqual(ring[3].filledEnd, ring[3].start, "half of six segments is three")
        let gauge = LiveGeometry.arcPieces(start: 270, sweep: 180, segments: 4, gap: 4, value: 1)
        XCTAssertEqual(gauge.map(\.start), [270, 316, 362, 408])
        XCTAssertEqual(gauge.last?.end, 450, "a partial sweep ends exactly at start + sweep")
        let partial = LiveGeometry.arcPieces(start: 0, sweep: 360, segments: 1, gap: 30, value: 0.25)
        XCTAssertEqual(partial, [LiveArcPiece(start: 0, end: 360, filledEnd: 90, index: 0)], "one segment has no gap")
    }

    /// Filled tiles from the start or the end, rounded and clamped, and cell sizes.
    func testGridFilledCells() {
        let start = (0..<10).filter { LiveGeometry.gridCellFilled($0, count: 10, filled: 7, fromEnd: false) }
        XCTAssertEqual(start, Array(0..<7))
        let end = (0..<10).filter { LiveGeometry.gridCellFilled($0, count: 10, filled: 7, fromEnd: true) }
        XCTAssertEqual(end, Array(3..<10))
        XCTAssertEqual((0..<6).filter { LiveGeometry.gridCellFilled($0, count: 6, filled: 3.6, fromEnd: false) }.count, 4)
        XCTAssertEqual((0..<6).filter { LiveGeometry.gridCellFilled($0, count: 6, filled: 99, fromEnd: false) }.count, 6)
        XCTAssertEqual((0..<6).filter { LiveGeometry.gridCellFilled($0, count: 6, filled: -2, fromEnd: true) }.count, 0)
        XCTAssertEqual(LiveGeometry.gridCell(width: 126, height: 82, cols: 3, rows: 2, gap: 6), CGSize(width: 38, height: 38))
        XCTAssertEqual(LiveGeometry.gridCell(width: 104, height: nil, cols: 5, rows: 2, gap: 6), CGSize(width: 16, height: 16))
    }

    /// The view box scales evenly to fit and centres; each copy is its def size times its scale times that factor.
    func testCopiesScaling() {
        let frames = LiveGeometry.copyFrames([[50, 50], [0, 0, 2], [1]], view: CGSize(width: 100, height: 100),
                                             box: CGSize(width: 200, height: 100), defSize: CGSize(width: 10, height: 10))
        XCTAssertEqual(frames, [CGRect(x: 95, y: 45, width: 10, height: 10), CGRect(x: 40, y: -10, width: 20, height: 20)])
        let smaller = LiveGeometry.copyFrames([[100, 50, 0.01]], view: CGSize(width: 200, height: 100),
                                              box: CGSize(width: 100, height: 100), defSize: CGSize(width: 20, height: 20))
        XCTAssertEqual(smaller, [CGRect(x: 49.5, y: 49.5, width: 1, height: 1)], "scale is at least 0.1, times the view's 0.5")
    }

    /// Amounts read numbers or number fields, clamped; lists read a `numbers` field or written numbers.
    func testAmountsFromFields() {
        let state = LiveState(title: "t", fields: ["share": .number(0.3), "big": .number(2.5), "neg": .number(-1), "word": .string("a"),
                                                   "history": .array([.number(66), .number(12), .string("x"), .number(0)])])
        let c = LiveContent(state: state, fields: [], accent: nil, appGroup: nil)
        XCTAssertEqual(c.amount(.number(0.5)), 0.5)
        XCTAssertEqual(c.amount(.number(7)), 1)
        XCTAssertEqual(c.amount(.string("share")), 0.3)
        XCTAssertEqual(c.amount(.string("big")), 1)
        XCTAssertEqual(c.amount(.string("neg")), 0)
        XCTAssertNil(c.amount(.string("word")))
        XCTAssertNil(c.amount(.string("missing")))
        XCTAssertNil(c.amount(nil))
        XCTAssertEqual(c.numbers(.string("history")), [66, 12, 0])
        XCTAssertEqual(c.numbers(.array([.number(1), .number(2)])), [1, 2])
        XCTAssertEqual(c.numbers(.string("share")), [])
        XCTAssertEqual(c.fill("{{history|none}}"), "none", "a list is no text")
        XCTAssertEqual(LiveGeometry.chartRange([66, 0], min: -40, max: nil, bars: false).0, -40)
        XCTAssertEqual(LiveGeometry.chartRange([5, 9], min: nil, max: nil, bars: true).0, 0, "bars start at 0")
    }

    /// `#RRGGBB` and `#RRGGBBAA`, nothing else.
    func testColours() throws {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        UIColor(try XCTUnwrap(PushPilotLiveBlock.hex("#FF000080"))).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b], [1, 0, 0])
        XCTAssertEqual(a, 128.0 / 255, accuracy: 0.001)
        UIColor(try XCTUnwrap(PushPilotLiveBlock.hex("#00FF00"))).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b, a], [0, 1, 0, 1])
        XCTAssertNil(PushPilotLiveBlock.hex("#00FF0"))
        XCTAssertNil(PushPilotLiveBlock.hex("00FF0080"))
    }

    /// Every reference design decodes as ActivityKit would, and uses only blocks, paths and defs the renderer has.
    func testDecodesEveryReferenceDesign() throws {
        XCTAssertGreaterThanOrEqual(LiveDesigns.names.count, 12)
        for name in LiveDesigns.names {
            let design = try LiveDesigns.load(name)
            let attributes = try JSONDecoder().decode(PushPilotLiveAttributes.self, from: design.attributes)
            let state = try JSONDecoder().decode(LiveState.self, from: design.state)
            XCTAssertFalse(state.title.isEmpty, name)
            XCTAssertNotNil(attributes.layout["lock"], name)
            XCTAssertNotNil(attributes.layout["small"], name)
            let defs = attributes.layout["defs"]
            for block in LiveDesigns.blocks(attributes.layout) {
                let type = try XCTUnwrap(block["type"]?.string)
                XCTAssertTrue(PushPilotLiveBlock.types.contains(type), "\(name): \(type)")
                if type == "path" { XCTAssertNotNil(LivePathParser.parse(block["d"]?.string ?? "x"), "\(name): \(block["d"] ?? .null)") }
                if type == "use" { XCTAssertNotNil(defs?[block["ref"]?.string ?? ""], "\(name): \(block["ref"] ?? .null)") }
            }
            for field in attributes.fields where field.kind == "numbers" {
                XCTAssertFalse(state.fields[field.name]?.items.isEmpty ?? true, "\(name): \(field.name)")
            }
        }
    }
}
