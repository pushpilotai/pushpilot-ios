import SwiftUI
import XCTest
@testable import PushPilotLive

/// Fixes found by comparing every design with its canvas (use placement, spacer boxes, two-line text, arc track).
@available(iOS 16.1, *)
final class LiveRendererFixTests: XCTestCase {
    /// Content with no fields.
    private let content = LiveContent(state: LiveState(title: "T"), fields: [], accent: nil, appGroup: nil)

    /// A block as JSON from a literal.
    private func json(_ text: String) -> LiveJSON { try! JSONDecoder().decode(LiveJSON.self, from: Data(text.utf8)) }

    /// The red, green and blue of one pixel of a block drawn at scale 1.
    @MainActor
    private func pixel(_ block: String, defs: String? = nil, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int)? {
        let renderer = ImageRenderer(content: PushPilotLiveBlock(json(block), content: content, defs: defs.map(json)))
        renderer.scale = 1
        guard let image = renderer.cgImage, x < image.width, y < image.height,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let at = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        return little ? (Int(bytes[at + 2]), Int(bytes[at + 1]), Int(bytes[at])) : (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
    }

    /// A use takes its def root's at, pos and fractions where it has none of its own; copies are left alone.
    func testUsePlacedFromDef() {
        let defs = json(##"{"d": {"type": "column", "w": 70, "fh": 1, "at": "trailing", "pos": [0.5, 0.5]}}"##)
        let drawer = PushPilotLiveBlock(.object([:]), content: content, defs: defs)
        let placed = drawer.placed(json(##"{"type": "use", "ref": "d", "at": "bottom"}"##))
        XCTAssertEqual(placed["at"], .string("bottom"))
        XCTAssertEqual(placed["fh"], .number(1))
        XCTAssertEqual(placed["pos"]?.items.count, 2)
        XCTAssertNil(drawer.placed(json(##"{"type": "use", "ref": "d", "copies": [[1, 1, 2]]}"##))["fh"])
        XCTAssertNil(drawer.placed(json(##"{"type": "text", "fh": null}"##))["at"])
    }

    /// Only drawings (or containers and uses holding one) take the space offered.
    func testIsDrawing() {
        let defs = json(##"{"pic": {"type": "path", "d": "M0 0L1 1"}, "badge": {"type": "text", "text": "LIVE"}}"##)
        let drawer = PushPilotLiveBlock(.object([:]), content: content, defs: defs)
        XCTAssertTrue(drawer.isDrawing(json(##"{"type": "layer", "items": [{"type": "text"}, {"type": "use", "ref": "pic"}]}"##)))
        XCTAssertFalse(drawer.isDrawing(json(##"{"type": "use", "ref": "badge"}"##)))
        XCTAssertFalse(drawer.isDrawing(json(##"{"type": "column", "items": [{"type": "text"}, {"type": "spacer"}]}"##)))
    }

    /// A use of an unsized def is placed by its own `at`, not centred by the def's.
    @MainActor
    func testUseAtWins() {
        let defs = ##"{"dot": {"type": "shape", "fill": "#ff0000"}}"##
        let layer = ##"{"type": "layer", "w": 100, "h": 40, "bg": "#000000", "items": [{"type": "use", "ref": "dot", "w": 10, "h": 10, "at": "top_trailing"}]}"##
        XCTAssertGreaterThan(pixel(layer, defs: defs, 95, 5)?.r ?? 0, 200)
        XCTAssertLessThan(pixel(layer, defs: defs, 50, 20)?.r ?? 255, 50)
    }

    /// A text def keeps its natural size instead of spreading its background over the box.
    @MainActor
    func testTextDefKeepsItsSize() {
        let defs = ##"{"badge": {"type": "text", "text": "LIVE", "size": 10, "bg": "#ff0000"}}"##
        let layer = ##"{"type": "layer", "w": 200, "h": 40, "bg": "#000000", "items": [{"type": "use", "ref": "badge", "at": "leading"}]}"##
        XCTAssertGreaterThan(pixel(layer, defs: defs, 2, 20)?.r ?? 0, 200)
        XCTAssertLessThan(pixel(layer, defs: defs, 190, 20)?.r ?? 255, 50)
    }

    /// A spacer draws its box: grid tiles of spacers with a background are filled cells.
    @MainActor
    func testSpacerDrawsItsBox() {
        let grid = ##"{"type": "grid", "w": 40, "h": 20, "cols": 2, "count": 2, "gap": 0, "filled": 1, "tile": {"type": "spacer", "bg": "#ff0000"}, "empty": {"type": "spacer", "bg": "#0000ff"}}"##
        XCTAssertGreaterThan(pixel(grid, 10, 10)?.r ?? 0, 200)
        XCTAssertGreaterThan(pixel(grid, 30, 10)?.b ?? 0, 200)
    }

    /// A two-line text before a drawing that fills the rest gets both its lines.
    @MainActor
    func testTwoLineTextKeepsItsLines() {
        let column = ##"{"type": "column", "w": 150, "h": 120, "spacing": 0, "items": [{"type": "text", "text": "Free delivery", "w": 150, "lines": 2, "size": 30, "weight": "heavy", "color": "#ff0000"}, {"type": "shape", "fill": "#0000ff"}]}"##
        // One line is about 36 points; with two the drawing starts below 60.
        XCTAssertLessThan(pixel(column, 75, 55)?.b ?? 255, 100)
        XCTAssertGreaterThan(pixel(column, 75, 110)?.b ?? 0, 200)
    }

    /// An arc between two times draws its track ring behind the system's ring.
    @MainActor
    func testTimerArcDrawsTrack() {
        let now = Date().timeIntervalSince1970
        let renderer = ImageRenderer(content: PushPilotLiveBlock(json(##"{"type": "arc", "w": 60, "h": 60, "from": "a", "to": "b", "width": 8, "track": "#ff0000", "color": "#00ff00"}"##),
                                                                 content: LiveContent(state: LiveState(title: "T", fields: ["a": .number(now + 100), "b": .number(now + 200)]),
                                                                                      fields: [], accent: nil, appGroup: nil)))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return XCTFail("no image") }
        // Somewhere on the left edge of the ring, the track's red shows.
        let reds = (20..<40).filter { y in
            (0..<8).contains { x in bytes[y * image.bytesPerRow + x * 4 + (image.bitmapInfo.contains(.byteOrder32Little) ? 2 : 0)] > 150 }
        }
        XCTAssertFalse(reds.isEmpty)
    }
}

/// A grid tile with its own size sits in the middle of its cell.
@available(iOS 16.1, *)
final class LiveGridCentreTests: XCTestCase {
    /// The red of one pixel of a block drawn at scale 1.
    @MainActor
    private func red(_ block: String, _ x: Int, _ y: Int) -> Int? {
        let content = LiveContent(state: LiveState(title: "T"), fields: [], accent: nil, appGroup: nil)
        let renderer = ImageRenderer(content: PushPilotLiveBlock(try! JSONDecoder().decode(LiveJSON.self, from: Data(block.utf8)), content: content))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        return Int(bytes[y * image.bytesPerRow + x * image.bitsPerPixel / 8 + (image.bitmapInfo.contains(.byteOrder32Little) ? 2 : 0)])
    }

    /// A 10-point tile in a 40 by 40 cell covers the cell's centre, not its corner.
    @MainActor
    func testSizedTileIsCentred() {
        let grid = ##"{"type": "grid", "w": 80, "h": 40, "cols": 2, "count": 2, "gap": 0, "filled": 2, "tile": {"type": "shape", "w": 10, "h": 10, "fill": "#ff0000"}}"##
        XCTAssertGreaterThan(red(grid, 20, 20) ?? 0, 200)
        XCTAssertGreaterThan(red(grid, 60, 20) ?? 0, 200)
        XCTAssertLessThan(red(grid, 2, 2) ?? 255, 50)
    }
}
