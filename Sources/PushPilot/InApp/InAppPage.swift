import CoreGraphics
import Foundation

/// Building the page the web view loads (IN-APP-SDK.md sections 2, 4 and 5). Pure functions, so they are tested directly.
enum InAppPage {
    /// The fixed base URL every page is loaded with.
    static let baseURL = URL(string: "https://in-app.pushpilot.invalid/")!
    /// Below this much memory the light page is chosen (I9, chosen during the build).
    static let slowPhoneMemory: UInt64 = 3 * 1024 * 1024 * 1024

    /// Whether a phone with `physicalMemory` bytes counts as slow.
    static func isSlowPhone(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory < slowPhoneMemory
    }

    /// The page URL to download and whether it is the light page: the light one on a slow phone when there is one.
    static func pageURL(_ message: InAppMessage, slow: Bool) -> (url: String, light: Bool) {
        if slow, let light = message.lightHtmlUrl, !light.isEmpty { return (light, true) }
        return (message.htmlUrl, false)
    }

    /// The cache file name for a message version, or nil when the id is not a UUID (it becomes part of a path).
    static func cacheFile(id: String, version: Int, light: Bool) -> String? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return "\(uuid.uuidString.lowercased()).v\(version)\(light ? ".light" : "").html"
    }

    /// Replaces every occurrence of each asset URL with a `data:` URI of its bytes. Longer URLs go first,
    /// so a URL that starts with another asset's URL is not cut in half.
    static func inline(_ html: String, assets: [String: (data: Data, mime: String)]) -> String {
        var page = html
        for url in assets.keys.sorted(by: { $0.count > $1.count }) where !url.isEmpty {
            let asset = assets[url]!
            page = page.replacingOccurrences(of: url, with: "data:\(asset.mime);base64,\(asset.data.base64EncodedString())")
        }
        return page
    }

    /// The `connect-src` sources: allowed origins that are plain http(s) origins, or `'none'`. Anything else is
    /// dropped, since a `;` or quote in an origin would add directives to the policy or end the attribute.
    static func connectSources(_ origins: [String]) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:/[]")
        let valid = origins.filter { origin in
            guard origin.allSatisfy(safe.contains), let url = URL(string: origin), ["http", "https"].contains(url.scheme),
                  url.host?.isEmpty == false, url.path.isEmpty || url.path == "/", url.query == nil else { return false }
            return true
        }
        return valid.isEmpty ? "'none'" : valid.joined(separator: " ")
    }

    /// The content security policy meta element.
    static func csp(_ origins: [String]) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; "
            + "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src \(connectSources(origins))\">"
    }

    /// The values the bridge hands the page, in points (CSS px).
    struct Values {
        var insets: (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) = (0, 0, 0, 0)
        var island: CGRect?
        var target: CGRect?
        var light = false
        var posture = InAppPosture(state: "flat", width: 0, height: 0)
    }

    /// A rect as a JS object literal, or `null`.
    static func js(_ rect: CGRect?) -> String {
        guard let r = rect else { return "null" }
        return "{x:\(number(r.minX)),y:\(number(r.minY)),width:\(number(r.width)),height:\(number(r.height))}"
    }

    /// A finite number as JS; anything else as 0.
    private static func number(_ value: CGFloat) -> String {
        value.isFinite ? "\(Double(value))" : "0"
    }

    /// The bridge script: defines a frozen `window.pushpilot` before any page script runs. Messages go to the
    /// `pushpilot` script message handler as one JSON string. Geolocation is removed, as the page has no use for it.
    /// `posture` is read through a getter, so `_posture(…)` (run by the SDK on every change) can update it.
    static func bridge(_ v: Values) -> String {
        let i = v.insets
        return """
        <script>(function(){var send=function(t,v){try{window.webkit.messageHandlers.pushpilot.postMessage(JSON.stringify({type:t,value:v==null?"":String(v)}))}catch(e){}};\
        var fz=function(q){if(q&&q.screen)Object.freeze(q.screen);return Object.freeze(q)},cur=fz(\(v.posture.json)),fns=[],call=function(f){try{f(cur)}catch(e){}};\
        var p={close:function(){send("close")},open:function(u){send("open",u)},haptic:function(k){send("haptic",k)},track:function(b){send("track",b)},\
        insets:Object.freeze({top:\(number(i.top)),right:\(number(i.right)),bottom:\(number(i.bottom)),left:\(number(i.left))}),\
        island:\(js(v.island)),target:\(js(v.target)),platform:"ios",light:\(v.light),\
        get posture(){return cur},onPosture:function(f){if(typeof f==="function"){fns.push(f);call(f)}},\
        _posture:function(q){cur=fz(q);fns.slice().forEach(call);try{window.dispatchEvent(new CustomEvent("pushpilotposture",{detail:cur}))}catch(e){}}};\
        if(p.island)Object.freeze(p.island);if(p.target)Object.freeze(p.target);\
        Object.defineProperty(window,"pushpilot",{value:Object.freeze(p),writable:false,configurable:false});\
        try{Object.defineProperty(navigator,"geolocation",{value:undefined,configurable:false})}catch(e){}})();</script>
        """
    }

    /// The script the SDK runs on a posture change.
    static func postureUpdate(_ posture: InAppPosture) -> String {
        "window.pushpilot&&window.pushpilot._posture(\(posture.json));"
    }

    /// Inserts the CSP meta element and the bridge script right after `<head>` (the tag may carry attributes),
    /// or at the very start when the page has no `<head>`.
    static func prepare(_ html: String, origins: [String], values: Values) -> String {
        let inserted = csp(origins) + bridge(values)
        var search = html.startIndex
        while let open = html.range(of: "<head", options: .caseInsensitive, range: search..<html.endIndex) {
            // `<head>` or `<head lang=…>`, not `<header>`.
            if open.upperBound < html.endIndex, ">\t\n\r /".contains(html[open.upperBound]),
               let close = html[open.upperBound...].firstIndex(of: ">") {
                let at = html.index(after: close)
                return String(html[..<at]) + inserted + String(html[at...])
            }
            search = open.upperBound
        }
        return inserted + html
    }
}
