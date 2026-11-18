import SwiftUI
import XCTest
@testable import PushPilotLive

/// Draws every reference design the way the widget does (Lock Screen, compact and expanded island, small view)
/// with `ImageRenderer` at 3x, checks each part draws something, and writes one sheet per design laid out like
/// the canvas reference images, for comparing by eye.
@available(iOS 16.1, *)
@MainActor
final class LiveSnapshotTests: XCTestCase {
    /// Where the sheets go: `PUSHPILOT_SNAPSHOT_DIR` (pass `TEST_RUNNER_PUSHPILOT_SNAPSHOT_DIR` to xcodebuild), else the temporary folder.
    private var outputDirectory: URL {
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("ios-png", isDirectory: true)
        guard let path = ProcessInfo.processInfo.environment["PUSHPILOT_SNAPSHOT_DIR"] else { return fallback }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil { return url }
        return fallback
    }

    /// Every design's four views draw something, and its sheet is written.
    func testRendersEveryReferenceDesign() throws {
        let out = outputDirectory
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in LiveDesigns.names {
            let design = try LiveDesigns.load(name, timeOffset: name == "group_order_2" ? 510 : 312)
            let a = try JSONDecoder().decode(PushPilotLiveAttributes.self, from: design.attributes)
            let state = try JSONDecoder().decode(LiveState.self, from: design.state)
            let content = LiveContent(state: state, fields: a.fields, accent: a.accent, appGroup: nil)
            let parts: [(String, AnyView)] = [("lock", AnyView(lock(a.layout, content))), ("compact", AnyView(compact(a.layout, content))),
                                              ("expanded", AnyView(expanded(a.layout, content))), ("small", AnyView(small(a.layout, content)))]
            for (part, view) in parts {
                let image = try XCTUnwrap(render(view), "\(name) \(part)")
                XCTAssertTrue(drawsSomething(image), "\(name) \(part) is blank")
            }
            let sheet = try XCTUnwrap(render(AnyView(self.sheet(parts))))
            try XCTUnwrap(UIImage(cgImage: sheet).pngData()).write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    /// The Lock Screen card: 376 points wide, at most 160 high, the lock `bg` as the activity's tint, clipped round.
    private func lock(_ layout: LiveJSON, _ content: LiveContent) -> some View {
        LiveLockView.lock(layout, content)
            .frame(width: 376)
            .frame(maxHeight: 160)
            .background(LiveLockView.background(layout, content) ?? Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// The compact Dynamic Island: leading and trailing regions in a 240 by 36 black pill.
    private func compact(_ layout: LiveJSON, _ content: LiveContent) -> some View {
        HStack {
            region(layout["island"]?["compact_leading"], layout, content)
            Spacer(minLength: 0)
            region(layout["island"]?["compact_trailing"], layout, content)
        }
        .padding(.horizontal, 14)
        .frame(width: 240, height: 36)
        .background(Capsule().fill(Color.black))
        .environment(\.colorScheme, .dark)
    }

    /// The expanded Dynamic Island: leading, centre and trailing in a row, bottom below, in a black 376 point card.
    private func expanded(_ layout: LiveJSON, _ content: LiveContent) -> some View {
        let island = layout["island"]
        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                region(island?["leading"], layout, content)
                Spacer(minLength: 0)
                region(island?["center"], layout, content)
                Spacer(minLength: 0)
                region(island?["trailing"], layout, content)
            }
            region(island?["bottom"], layout, content)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(width: 376)
        .frame(minHeight: 160)
        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Color.black))
        .environment(\.colorScheme, .dark)
    }

    /// The small view for Apple Watch and CarPlay, in a 180 by 76 card.
    private func small(_ layout: LiveJSON, _ content: LiveContent) -> some View {
        LiveLockView.small(layout, content)
            .frame(width: 180, height: 76)
            .background(LiveLockView.background(layout, content) ?? Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// One region block, nothing for a spacer region.
    @ViewBuilder
    private func region(_ block: LiveJSON?, _ layout: LiveJSON, _ content: LiveContent) -> some View {
        if let block, block["type"]?.string != "spacer" { PushPilotLiveBlock(block, content: content, defs: layout["defs"]) }
    }

    /// The four parts under labels, like the canvas reference images.
    private func sheet(_ parts: [(String, AnyView)]) -> some View {
        let titles = ["lock": "LOCK SCREEN", "compact": "COLLAPSED", "expanded": "EXPANDED", "small": "SMALL (WATCH, CARPLAY)"]
        let order = ["compact", "expanded", "lock", "small"]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(order, id: \.self) { key in
                Text(titles[key] ?? key).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundColor(Color(white: 0.35)).padding(.top, 10)
                HStack { Spacer(minLength: 0); parts.first { $0.0 == key }?.1; Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .frame(width: 440)
        .background(Color(red: 235 / 255, green: 235 / 255, blue: 240 / 255))
        .environment(\.colorScheme, .light)
    }

    /// A view drawn at 3x.
    private func render(_ view: AnyView) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.cgImage
    }

    /// Whether an image has more than one colour.
    private func drawsSomething(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data), stride = max(image.bitsPerPixel / 8, 1)
        let first = Array(UnsafeBufferPointer(start: bytes, count: stride))
        return Swift.stride(from: 0, to: length - stride, by: stride * 7).contains { i in
            (0..<stride).contains { bytes[i + $0] != first[$0] }
        }
    }
}
