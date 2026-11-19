import CoreGraphics

/// How the device is folded and the size of the screen the page is on, in points (IN-APP-SDK.md section 9).
struct InAppPosture: Equatable {
    /// The states the page may see; anything else is sent as `flat`.
    static let states: Set<String> = ["closed", "opening", "half_open", "tabletop", "open", "flat"]

    let state: String
    let width: CGFloat
    let height: CGFloat

    /// The posture as JSON, which is also a JS literal: `{"state":…,"screen":{"width":…,"height":…}}`.
    var json: String {
        let state = Self.states.contains(state) ? state : "flat"
        /// A finite number, else 0.
        func number(_ v: CGFloat) -> String { v.isFinite ? "\(Double(v))" : "0" }
        return #"{"state":"\#(state)","screen":{"width":\#(number(width)),"height":\#(number(height))}}"#
    }
}

/// Reads the device's posture. The installed iOS SDK has no iPhone Duo hinge API, so the only source is
/// `FlatPostureSource`; a real one replaces it once Apple's API is in the SDK (chosen during the build).
protocol InAppPostureSource {
    /// The posture for a window of `size` points.
    func posture(windowSize size: CGSize) -> InAppPosture
    /// Calls `changed` when the fold changes without the window changing size.
    func observe(_ changed: @escaping () -> Void)
}

/// The stub: every device is `flat`, with the window's size.
struct FlatPostureSource: InAppPostureSource {
    /// `flat` with the window size.
    func posture(windowSize size: CGSize) -> InAppPosture {
        InAppPosture(state: "flat", width: size.width, height: size.height)
    }

    /// A flat phone never changes fold.
    func observe(_ changed: @escaping () -> Void) {}
}
