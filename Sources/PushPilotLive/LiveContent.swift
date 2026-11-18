import CoreGraphics
import CryptoKit
import Foundation

/// The state of one activity as the layout reads it: tokens, numbers, times and image files.
/// Pure, so the widget and the tests share it.
public struct LiveContent {
    public let state: LiveState
    /// Field name to kind.
    public let kinds: [String: String]
    public let accent: String?
    /// The App Group that holds downloaded images, if the app set one.
    public let appGroup: String?
    /// The text `{{label}}` shows inside a grid cell; nil outside a grid with `labels`.
    public var label: String?

    /// Content for a state and the activity's fields.
    public init(state: LiveState, fields: [LiveField], accent: String?, appGroup: String?) {
        self.state = state
        self.kinds = Dictionary(fields.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a })
        self.accent = accent
        self.appGroup = appGroup
    }

    private static let token = try! NSRegularExpression(pattern: #"\{\{\s*([a-z][a-z0-9_]*)\s*(\|[^}]*)?\}\}"#)

    /// Fills `{{title}}`, `{{field}}` and `{{field|fallback}}`: times in the device's short local time,
    /// numbers as written, the fallback when the value is missing or empty.
    public func fill(_ text: String?, time: (Date) -> String = { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) }) -> String {
        guard let text, !text.isEmpty else { return "" }
        var out = ""
        var last = text.startIndex
        let ns = text as NSString
        for match in Self.token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let whole = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            let name = String(text[nameRange])
            let fallback = Range(match.range(at: 2), in: text).map { String(text[$0].dropFirst()) } ?? ""
            let value = name == "title" ? state.title : name == "label" && label != nil ? label : display(name, time: time)
            out += (value?.isEmpty == false ? value! : fallback)
            last = whole.upperBound
        }
        return out + text[last...]
    }

    /// A field's value as text, or nil when it is missing.
    private func display(_ name: String, time: (Date) -> String) -> String? {
        switch state.fields[name] {
        case .number(let v)?:
            if kinds[name] == "time" { return time(Date(timeIntervalSince1970: v)) }
            return Self.numberText(v)
        case .string(let v)?: return v
        case .bool(let v)?: return v ? "true" : "false"
        default: return nil
        }
    }

    /// A number as written: no trailing `.0` on whole numbers.
    public static func numberText(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// A number field, or nil.
    public func number(_ name: String?) -> Double? { name.flatMap { state.fields[$0]?.number } }

    /// A time field as a date, or nil.
    public func date(_ name: String?) -> Date? { number(name).map { Date(timeIntervalSince1970: $0) } }

    /// An *amount* (LIVE.md "Contract version 2"): a number, or the name of a number field, clamped to 0…1;
    /// nil when absent or the field has no number.
    public func amount(_ value: LiveJSON?) -> Double? {
        self.value(value).map { min(max($0, 0), 1) }
    }

    /// A number written in the layout, or read from the number field it names.
    public func value(_ json: LiveJSON?) -> Double? {
        if case .string(let name)? = json { return number(name) }
        return json?.number
    }

    /// A list of numbers: written in the layout, or the name of a `numbers` field; non-numbers are skipped.
    public func numbers(_ value: LiveJSON?) -> [Double] {
        let list: [LiveJSON]
        switch value {
        case .array(let items)?: list = items
        case .string(let name)?: list = state.fields[name]?.items ?? []
        default: list = []
        }
        return list.compactMap(\.number)
    }

    /// A progress block's value from 0 to 1 at `now`: its number field, or how far now is between its two times.
    public func fraction(_ block: LiveJSON, now: Date = Date()) -> Double {
        if let value = block["value"]?.string { return min(max(number(value) ?? 0, 0), 1) }
        guard let from = date(block["from"]?.string), let to = date(block["to"]?.string) else { return 0 }
        guard to > from else { return 1 }
        return min(max(now.timeIntervalSince(from) / to.timeIntervalSince(from), 0), 1)
    }

    /// Whether a block with this `show` is drawn: every condition given holds (`is` equal as text or number,
    /// `above`/`below` as numbers, a time in Unix seconds); with only `field`, the value is present and not
    /// empty, 0 or false. No `show` (or no `field`) always shows.
    public func shows(_ show: LiveJSON?) -> Bool {
        guard let show, let field = show["field"]?.string else { return true }
        let value = field == "title" ? .string(state.title) : state.fields[field]
        let text: String? = value?.number.map(Self.numberText) ?? value?.string
        if let wanted = show["is"] {
            switch wanted {
            case .number(let n): if value?.number != n { return false }
            case .string(let t): if text != t { return false }
            default: if value != wanted { return false }
            }
        }
        if let above = show["above"]?.number, !((value?.number).map { $0 > above } ?? false) { return false }
        if let below = show["below"]?.number, !((value?.number).map { $0 < below } ?? false) { return false }
        if show["is"] != nil || show["above"] != nil || show["below"] != nil { return true }
        switch value {
        case .string(let t)?: return !t.isEmpty
        case .number(let n)?: return n != 0
        case .bool(let b)?: return b
        case .array(let items)?: return !items.isEmpty
        case .object?: return true
        default: return false
        }
    }

    /// A grid's `labels`, one per cell: a list of texts each filled, or one text filled and split into its
    /// characters; at most `limit`.
    public func labels(_ json: LiveJSON?, limit: Int = 96) -> [String] {
        switch json {
        case .array(let items)?: return items.prefix(limit).map { fill($0.string) }
        case .string(let text)?: return fill(text).prefix(limit).map(String.init)
        default: return []
        }
    }

    /// Which cells of a grid of `count` are filled: by a list of numbers (written, or a `numbers` field),
    /// cell *i* when entry *i* is not 0; else the first (or last) `filled` cells.
    public func gridFilled(_ filled: LiveJSON?, count: Int, fromEnd: Bool) -> [Bool] {
        var list = false
        if case .array? = filled { list = true }
        if case .string(let name)? = filled, case .array? = state.fields[name] { list = true }
        if list {
            let mask = numbers(filled)
            return (0..<count).map { mask.indices.contains($0) && mask[$0] != 0 }
        }
        let n = value(filled) ?? 0
        return (0..<count).map { LiveGeometry.gridCellFilled($0, count: count, filled: n, fromEnd: fromEnd) }
    }

    /// `pos`: `[x, y]`, each an amount, as a fraction of a layer's size; nil unless both resolve.
    public func pos(_ json: LiveJSON?) -> CGPoint? {
        guard let p = json?.items, p.count == 2, let x = amount(p[0]), let y = amount(p[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Where a downloaded image of `url` is kept in the App Group, shared by the app (writing) and the widget (reading).
    public static func imageFile(url: String, appGroup: String) -> URL? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("PushPilotLive", isDirectory: true).appendingPathComponent(name)
    }

    /// Every image `url` in a layout, tokens not yet filled.
    public static func imageUrls(_ json: LiveJSON) -> [String] {
        switch json {
        case .object(let o):
            let own = o["type"]?.string == "image" ? [o["url"]?.string].compactMap { $0 } : []
            return own + o.keys.sorted().flatMap { imageUrls(o[$0]!) }
        case .array(let a): return a.flatMap(imageUrls)
        default: return []
        }
    }
}
