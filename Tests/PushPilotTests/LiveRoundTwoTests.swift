import SwiftUI
import XCTest
@testable import PushPilotLive

/// Layout contract version 2, round two (LIVE.md "Round two: pieces found while writing all 87 designs").
@available(iOS 16.1, *)
final class LiveRoundTwoTests: XCTestCase {
    /// Shorthand for a point.
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// Content with these fields, all numbers, texts or lists as given.
    private func content(_ fields: [String: LiveJSON], title: String = "Order") -> LiveContent {
        LiveContent(state: LiveState(title: title, fields: fields), fields: [LiveField(name: "eta", kind: "time")], accent: nil, appGroup: nil)
    }

    /// Two points within a hundredth of each other.
    private func near(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.01, file: file, line: line)
    }

    /// The cubic curves of a parsed path, after its first move.
    private func cubics(_ d: String) -> [(CGPoint, CGPoint, CGPoint)] {
        (LivePathParser.parse(d) ?? []).compactMap { if case .cubic(let a, let b, let c) = $0 { return (a, b, c) } else { return nil } }
    }

    /// A quarter circle is one cubic with the standard 0.5523 control length.
    func testArcQuarterCircle() {
        let c = cubics("M0 0A10 10 0 0 1 10 10")
        XCTAssertEqual(c.count, 1)
        near(c[0].0, p(5.523, 0))
        near(c[0].1, p(10, 4.477))
        near(c[0].2, p(10, 10))
    }

    /// A half circle is two curves through the top; radii too small to reach are grown; compact flags and
    /// relative ends read as SVG reads them.
    func testArcHalfCircleAndScaling() {
        for d in ["M0 0A5 5 0 0 1 10 0", "M0 0A1 1 0 0 1 10 0", "M0 0a5 5 0 0110 0"] {
            let c = cubics(d)
            XCTAssertEqual(c.count, 2, d)
            near(c[0].2, p(5, -5))
            near(c[1].2, p(10, 0))
        }
        // The other sweep goes through the bottom; the large arc of a circle through two close points goes the long way.
        near(cubics("M0 0A5 5 0 0 0 10 0")[0].2, p(5, 5))
        XCTAssertEqual(cubics("M0 0A10 10 0 1 1 10 10").count, 3)
        let lines = LivePathGeometry.polylines(LivePathParser.parse("M0 0A5 5 0 0 1 10 0")!)
        near(LivePathGeometry.point(at: 0.5, in: lines)!, p(5, -5))
    }

    /// Edge cases of arcs: a zero radius is a line, the same end is nothing, a bad flag refuses the path,
    /// and an `S` after an arc takes the current point as its first control.
    func testArcEdgeCases() {
        XCTAssertEqual(LivePathParser.parse("M0 0A0 5 0 0 1 10 0"), [.move(p(0, 0)), .line(p(10, 0))])
        XCTAssertEqual(LivePathParser.parse("M3 3A5 5 0 0 1 3 3"), [.move(p(3, 3))])
        XCTAssertNil(LivePathParser.parse("M0 0A5 5 0 2 1 10 0"), "a flag must be 0 or 1")
        XCTAssertNil(LivePathParser.parse("M0 0A5 5 0 0 1 10"), "an arc without its end")
        guard case .cubic(let c1, _, _)? = LivePathParser.parse("M0 0A5 5 0 0 1 10 0S20 10 20 0")?.last else { return XCTFail("no curve") }
        XCTAssertEqual(c1, p(10, 0))
    }

    /// A rotated ellipse still ends exactly where asked.
    func testArcRotatedEllipse() {
        let c = cubics("M10 10A20 8 30 1 0 40 25")
        XCTAssertGreaterThan(c.count, 1)
        XCTAssertEqual(c.last?.2, p(40, 25))
    }

    /// `show` with only `field`, with `is`, `above` and `below`, on `title` and on a time.
    func testShowConditions() {
        let c = content(["star": .bool(true), "off": .bool(false), "zero": .number(0), "n": .number(3), "empty": .string(""),
                         "who": .string("you"), "eta": .number(1_800_000_000), "list": .array([.number(1)])])
        XCTAssertTrue(c.shows(nil))
        XCTAssertTrue(c.shows(.object(["field": .string("star")])))
        for hidden in ["off", "zero", "empty", "missing"] {
            XCTAssertFalse(c.shows(.object(["field": .string(hidden)])), hidden)
        }
        XCTAssertTrue(c.shows(.object(["field": .string("list")])))
        XCTAssertTrue(c.shows(.object(["field": .string("who"), "is": .string("you")])))
        XCTAssertFalse(c.shows(.object(["field": .string("who"), "is": .string("them")])))
        XCTAssertTrue(c.shows(.object(["field": .string("n"), "is": .number(3)])))
        XCTAssertTrue(c.shows(.object(["field": .string("n"), "is": .string("3")])), "a number compares as text too")
        XCTAssertTrue(c.shows(.object(["field": .string("zero"), "is": .number(0)])), "is 0 shows a 0")
        XCTAssertTrue(c.shows(.object(["field": .string("n"), "above": .number(2), "below": .number(4)])))
        XCTAssertFalse(c.shows(.object(["field": .string("n"), "above": .number(3)])), "above is strict")
        XCTAssertFalse(c.shows(.object(["field": .string("who"), "above": .number(0)])), "text is not a number")
        XCTAssertFalse(c.shows(.object(["field": .string("missing"), "below": .number(10)])))
        XCTAssertTrue(c.shows(.object(["field": .string("eta"), "above": .number(1_700_000_000)])), "a time in Unix seconds")
        XCTAssertTrue(c.shows(.object(["field": .string("title"), "is": .string("Order")])))
    }

    /// `labels` as a list of filled texts, or one filled text split into characters, cut to the cell count.
    func testLabels() {
        let c = content(["code": .string("AB1👍🏽"), "day": .string("Mon")])
        XCTAssertEqual(c.labels(.string("{{code}}")), ["A", "B", "1", "👍🏽"])
        XCTAssertEqual(c.labels(.array([.string("{{day}}"), .string("Tue")])), ["Mon", "Tue"])
        XCTAssertEqual(c.labels(.string("ABCDE"), limit: 3), ["A", "B", "C"])
        XCTAssertEqual(c.labels(nil), [])
        var cell = c
        cell.label = "Q"
        XCTAssertEqual(cell.fill("[{{label}}]"), "[Q]")
        cell.label = ""
        XCTAssertEqual(cell.fill("{{label|-}}"), "-")
    }

    /// `filled` as a count, from the end, or a numbers list marking each cell.
    func testGridFilled() {
        let c = content(["done": .number(2), "seen": .array([.number(1), .number(0), .number(2)])])
        XCTAssertEqual(c.gridFilled(.string("done"), count: 4, fromEnd: false), [true, true, false, false])
        XCTAssertEqual(c.gridFilled(.string("done"), count: 4, fromEnd: true), [false, false, true, true])
        XCTAssertEqual(c.gridFilled(.string("seen"), count: 4, fromEnd: false), [true, false, true, false])
        XCTAssertEqual(c.gridFilled(.array([.number(0), .number(5)]), count: 2, fromEnd: false), [false, true])
        XCTAssertEqual(c.gridFilled(nil, count: 2, fromEnd: false), [false, false])
    }

    /// `pos` reads two amounts, clamped, either written or from number fields.
    func testPos() {
        let c = content(["p": .number(0.5), "big": .number(1.5), "t": .string("x")])
        XCTAssertEqual(c.pos(.array([.number(0.33), .string("p")])), p(0.33, 0.5))
        XCTAssertEqual(c.pos(.array([.string("big"), .number(-1)])), p(1, 0))
        XCTAssertNil(c.pos(.array([.string("t"), .number(0)])))
        XCTAssertNil(c.pos(.array([.number(0.5)])))
        XCTAssertNil(c.pos(nil))
    }

    /// A layer item with `pos` is centred at that fraction of the layer, instead of its `at`.
    @MainActor
    func testPosPlacesInLayer() {
        let c = content([:])
        let layout: LiveJSON = .object(["type": .string("layer"), "w": .number(200), "h": .number(100), "bg": .string("#000000"),
                                        "items": .array([.object(["type": .string("shape"), "w": .number(10), "h": .number(10),
                                                                  "fill": .string("#ff0000"), "at": .string("top_leading"),
                                                                  "pos": .array([.number(0.75), .number(0.5)])])])])
        let renderer = ImageRenderer(content: PushPilotLiveBlock(layout, content: c))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return XCTFail("no image") }
        /// The red channel at a pixel.
        func red(_ x: Int, _ y: Int) -> UInt8 { bytes[y * image.bytesPerRow + x * image.bitsPerPixel / 8 + (image.bitmapInfo.contains(.byteOrder32Little) ? 2 : 0)] }
        XCTAssertGreaterThan(red(150, 50), 200, "the dot is centred at 75 % across, half way down")
        XCTAssertLessThan(red(5, 5), 50, "not at its top_leading")
    }

    /// `use.colors` over the enclosing def's colours, `$` values taken from them, unset names primary;
    /// a def starts from its own `view`.
    func testUseColorsAndView() {
        let outer = PushPilotLiveBlock(.object([:]), content: content([:])).with { $0.palette = ["a": "#ff0000"]; $0.viewBox = CGSize(width: 1, height: 1) }
        let inner = outer.inside(.object(["type": .string("path"), "view": .array([.number(24), .number(24)])]),
                                 colors: .object(["b": .string("$a"), "c": .string("$zz"), "d": .string("#00ff00")]))
        XCTAssertEqual(inner.palette, ["a": "#ff0000", "b": "#ff0000", "c": "primary", "d": "#00ff00"])
        XCTAssertEqual(inner.viewBox, CGSize(width: 24, height: 24))
        XCTAssertNil(outer.inside(.object([:]), colors: nil).viewBox, "a def without view inherits nothing from outside")
        XCTAssertEqual(inner.color("$b"), PushPilotLiveBlock.hex("#ff0000"))
        XCTAssertEqual(inner.color("$unset"), .primary)
    }

    /// Timer formats name their units; on iOS 18 the offset reads without a sign.
    func testTimerFormats() {
        XCTAssertNil(PushPilotLiveBlock.timerUnits(nil))
        XCTAssertNil(PushPilotLiveBlock.timerUnits("clock"))
        XCTAssertEqual(PushPilotLiveBlock.timerUnits("hours"), [.hour, .minute])
        XCTAssertEqual(PushPilotLiveBlock.timerUnits("days"), [.day, .hour])
        if #available(iOS 18.0, *) {
            let now = Date()
            let text = String(SystemFormatStyle.DateOffset(to: now.addingTimeInterval(25 * 60 + 10), allowedFields: [.minute], maxFieldCount: 1, sign: .never)
                .format(now).characters)
            XCTAssertTrue(text.contains("25"), text)
            XCTAssertFalse(text.contains("-") || text.contains("−"), text)
        }
    }
}
