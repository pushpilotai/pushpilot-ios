#if canImport(ActivityKit) && canImport(WidgetKit) && canImport(UIKit)
import SwiftUI

@available(iOS 16.1, *)
extension PushPilotLiveBlock {
    /// A `text` block: its `text`, or its `runs` joined into one line, with style, size, weight, colour,
    /// tracking, `mono`, `strike`, `italic` and `upper`; `number` digits roll on change.
    func text(_ b: LiveJSON) -> some View {
        let runs = b["runs"]?.items ?? []
        let line = runs.isEmpty
            ? styled(b["text"]?.string, run: nil, b)
            : runs.reduce(Text("")) { $0 + styled($1["text"]?.string, run: $1, b) }
        return line
            .multilineTextAlignment(textAlignment(b))
            .lineLimit(Int(min(max(b["lines"]?.number ?? 1, 1), 4))) // clamped: Int(_:) traps on a huge Double
            .contentTransition(.numericText())
    }

    /// One piece of text with the block's look, a run's own `color`, `weight`, `size` and `strike` on top.
    private func styled(_ raw: String?, run: LiveJSON?, _ b: LiveJSON) -> Text {
        var value = content.fill(raw)
        if b["upper"] == .bool(true) { value = value.uppercased() }
        let size = run?["size"]?.number ?? b["size"]?.number
        var text = Text(value).font(font(style: b["style"]?.string, size: size, weight: run?["weight"]?.string ?? b["weight"]?.string,
                                         italic: b["italic"] == .bool(true), mono: b["mono"] == .bool(true)))
        if let c = color(run?["color"]?.string ?? b["color"]?.string) { text = text.foregroundColor(c) }
        if (run?["strike"] ?? b["strike"]) == .bool(true) { text = text.strikethrough() }
        if let em = b["tracking"]?.number { text = text.tracking(CGFloat(em) * fontSize(style: b["style"]?.string, size: size)) }
        return text
    }

    /// Counts down to, or up from, a time field, with the same look keys as text.
    @ViewBuilder
    func timer(_ b: LiveJSON) -> some View {
        if let date = content.date(b["field"]?.string) {
            timerText(b, until: date)
                .foregroundColor(color(b["color"]?.string))
                .multilineTextAlignment(textAlignment(b))
                .lineLimit(1)
        }
    }

    /// The running text of a timer in its `format`, with its font and tracking; digits are always of equal width.
    private func timerText(_ b: LiveJSON, until date: Date) -> Text {
        let size = b["size"]?.number, style = b["style"]?.string
        var text: Text
        if let units = Self.timerUnits(b["format"]?.string) {
            if #available(iOS 18.0, *) {
                // A live duration runs by itself; narrow reads "2h 14m" and "1d 22h", abbreviated "25 min" and "42 secs".
                let style: Date.ComponentsFormatStyle.Style = units.count > 1 ? .narrow : .abbreviated
                let range: TimeDataSource<Range<Date>> = b["mode"]?.string == "up" ? .dateRange(startingAt: date) : .dateRange(endingAt: date)
                text = Text(range, format: .components(style: style, fields: Set(units)))
            } else {
                // shortcut: before iOS 18 the system's relative style is the only self-running unit text; it may add a smaller unit.
                text = Text(date, style: .relative)
            }
        } else {
            text = b["mode"]?.string == "up" ? Text(date, style: .timer) : Text(timerInterval: Date()...max(date, Date()), countsDown: true)
        }
        text = text.font(font(style: style, size: size, weight: b["weight"]?.string, italic: b["italic"] == .bool(true), mono: true))
        if let em = b["tracking"]?.number { text = text.tracking(CGFloat(em) * fontSize(style: style, size: size)) }
        return text
    }

    /// The units of a timer `format` other than `clock`, largest first; nil for `clock` or no format.
    static func timerUnits(_ format: String?) -> [Date.ComponentsFormatStyle.Field]? {
        switch format {
        case "minutes"?: return [.minute]
        case "hours"?: return [.hour, .minute]
        case "days"?: return [.day, .hour]
        case "seconds"?: return [.second]
        default: return nil
        }
    }

    /// A text's `align` (default leading).
    func textAlignment(_ b: LiveJSON) -> TextAlignment {
        b["align"]?.string == "center" ? .center : b["align"]?.string == "trailing" ? .trailing : .leading
    }

    /// Where a text sits in a box larger than itself: its `align`, or centred when it has none (a "VS"
    /// disc, a big "6" in a circle).
    func textBoxAlignment(_ b: LiveJSON) -> Alignment {
        switch b["align"]?.string {
        case "leading"?: return .leading
        case "trailing"?: return .trailing
        default: return .center
        }
    }
}
#endif
