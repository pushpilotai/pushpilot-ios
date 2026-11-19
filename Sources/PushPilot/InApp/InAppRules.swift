import CoreGraphics
import Foundation

/// Which message shows, where the island is, and what the page asked for (IN-APP-SDK.md sections 3, 5, 6 and 8).
/// Pure functions, so they are tested directly.
enum InAppRules {
    /// What asked for a message: the app coming to the foreground, or `showInApp(name)`.
    enum Trigger: Equatable {
        case appOpen
        case named(String)
    }

    /// Whether `message` waits for `trigger`.
    static func matches(_ message: InAppMessage, _ trigger: Trigger) -> Bool {
        switch trigger {
        case .appOpen: return message.trigger == "app_open"
        case .named(let name): return message.trigger == "show_in_app" && message.triggerName == name
        }
    }

    /// Whether the message is under its cap, counting the larger of this device's and the server's shown count.
    static func underCap(_ message: InAppMessage, localShown: Int) -> Bool {
        guard let cap = message.capPerDevice else { return true }
        return max(localShown, message.shownCount ?? 0) < cap
    }

    /// Whether `now` is within the message's dates. A date that cannot be read keeps the message hidden.
    static func inDates(_ message: InAppMessage, now: Date) -> Bool {
        if let starts = message.startsAt {
            guard let date = InAppDates.parse(starts), date <= now else { return false }
        }
        if let ends = message.endsAt {
            guard let date = InAppDates.parse(ends), now < date else { return false }
        }
        return true
    }

    /// The first cached message for `trigger` in the answer's order that may show now, with its coach-mark
    /// target. `target` gives the on-screen frame of a marked view, or nil when it is not attached and visible.
    static func pick(_ cache: InAppCache, trigger: Trigger, now: Date,
                     target: (String) -> CGRect?) -> (message: InAppMessage, page: InAppCachedPage, target: CGRect?)? {
        for message in cache.messages where matches(message, trigger) {
            guard let page = cache.pages[message.id], page.version == message.htmlVersion,
                  underCap(message, localShown: cache.shown[message.id] ?? 0), inDates(message, now: now) else { continue }
            if message.format == "coach_mark" {
                guard let name = message.coachTarget, let frame = target(name) else { continue }
                return (message, page, frame)
            }
            return (message, page, nil)
        }
        return nil
    }

    /// The Dynamic Island's frame in points (I14, chosen during the build): an iPhone in portrait whose top
    /// safe-area inset is 59 pt or more; nil for every other device and for landscape.
    static func island(topInset: CGFloat, size: CGSize, isPhone: Bool) -> CGRect? {
        guard isPhone, size.height > size.width, topInset >= 59 else { return nil }
        return CGRect(x: (size.width - 125) / 2, y: 11, width: 125, height: 37)
    }

    /// One request from the page.
    enum Command: Equatable {
        case close
        case open(URL)
        case haptic(String)
        case track(String)
    }

    /// Reads the bridge's JSON string `{"type", "value"}`; nil for anything else, a refused link included.
    static func command(_ body: Any) -> Command? {
        guard let text = body as? String, let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let value = json["value"] as? String ?? ""
        switch type {
        case "close": return .close
        case "open": return openableURL(value).map(Command.open)
        case "haptic": return .haptic(value)
        case "track": return .track(value)
        default: return nil
        }
    }

    /// A link the page may hand to the app: it has a scheme, and not `javascript:`, `data:`, `file:` or `blob:`.
    static func openableURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              !["javascript", "data", "file", "blob"].contains(scheme) else { return nil }
        return url
    }

    /// A button id the server accepts: 1 to 64 bytes.
    static func validButtonId(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
    }
}

/// One showing of a message: the events it produces. `dismissed` only when it closes after being shown
/// without any accepted `track` call.
struct InAppShowing {
    private(set) var shownAt: Date?
    private(set) var tracked = false

    /// An event the showing produced: type, button id and time.
    struct Event: Equatable {
        let type: String
        let buttonId: String?
        let at: Date
    }

    /// The page is on screen; nil if it was already.
    mutating func shown(at: Date) -> Event? {
        guard shownAt == nil else { return nil }
        shownAt = at
        return Event(type: "shown", buttonId: nil, at: at)
    }

    /// A `track(buttonId)` call; nil for an id the server would reject, which is not counted as a track.
    mutating func track(_ buttonId: String, at: Date) -> Event? {
        guard InAppRules.validButtonId(buttonId) else { return nil }
        tracked = true
        return Event(type: "clicked", buttonId: buttonId, at: at)
    }

    /// The message closed: `dismissed` if it was shown and nothing was tracked.
    func closed(at: Date) -> Event? {
        guard shownAt != nil, !tracked else { return nil }
        return Event(type: "dismissed", buttonId: nil, at: at)
    }
}
