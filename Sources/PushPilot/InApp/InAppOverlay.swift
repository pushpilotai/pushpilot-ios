#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// One message on screen: a full-screen transparent window holding a locked-down web view (IN-APP-SDK.md
/// sections 4 and 5). It lives until the page closes, opens a link, or fails to load.
@MainActor
final class InAppOverlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate, UIScrollViewDelegate {
    private let window: UIWindow
    private let webView: WKWebView
    private weak var previousKey: UIWindow?
    private var showing = InAppShowing()
    /// The initial load has been allowed; every later navigation is cancelled.
    private var loadStarted = false
    private var closed = false
    private let onEvent: (InAppShowing.Event) -> Void
    private let onClose: () -> Void
    private let postureSource: InAppPostureSource
    /// The posture the page last got.
    private var posture: InAppPosture

    /// Builds the web view, loads `html` with the fixed base URL and puts the window on screen.
    /// `posture` is the one the bridge script already carries; `postureSource` gives later ones.
    init(scene: UIWindowScene, html: String, posture: InAppPosture, postureSource: InAppPostureSource,
         onEvent: @escaping (InAppShowing.Event) -> Void, onClose: @escaping () -> Void) {
        self.onEvent = onEvent
        self.onClose = onClose
        self.posture = posture
        self.postureSource = postureSource
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false
        webView = WKWebView(frame: scene.coordinateSpace.bounds, configuration: config)
        window = UIWindow(windowScene: scene)
        previousKey = scene.windows.first { $0.isKeyWindow }
        super.init()
        // The handler is removed on close; WKUserContentController holds it strongly until then.
        config.userContentController.add(self, name: "pushpilot")

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let scroll = webView.scrollView
        scroll.backgroundColor = .clear
        scroll.bounces = false
        scroll.bouncesZoom = false
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.pinchGestureRecognizer?.isEnabled = false
        scroll.delegate = self
        // CSS px 0,0 is the screen's top left, so insets, island and target line up with the page.
        scroll.contentInsetAdjustmentBehavior = .never

        let root = InAppRootController()
        root.view.backgroundColor = .clear
        webView.frame = root.view.bounds
        root.view.addSubview(webView)
        window.rootViewController = root
        window.windowLevel = .alert
        window.backgroundColor = .clear
        window.makeKeyAndVisible()
        webView.loadHTMLString(html, baseURL: InAppPage.baseURL)
        root.layoutChanged = { [weak self] in self?.updatePosture() }
        postureSource.observe { [weak self] in self?.updatePosture() }
    }

    /// Sends the page the posture when it changed (window size, rotation, traits or fold).
    private func updatePosture() {
        let now = postureSource.posture(windowSize: window.bounds.size)
        guard !closed, now != posture else { return }
        posture = now
        webView.evaluateJavaScript(InAppPage.postureUpdate(now))
    }

    /// Ends the showing: reports `dismissed` when nothing was tracked, removes the window and gives the key back.
    func close() {
        guard !closed else { return }
        closed = true
        if let event = showing.closed(at: Date()) { onEvent(event) }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pushpilot")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        window.isHidden = true
        previousKey?.makeKey()
        onClose()
    }

    // MARK: WKScriptMessageHandler

    /// Runs one request from the main frame's page.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, let command = InAppRules.command(message.body) else { return }
        switch command {
        case .close:
            close()
        case .open(let url):
            PushPilot.openLink(url)
            close()
        case .haptic(let kind):
            Self.haptic(kind)
        case .track(let buttonId):
            if let event = showing.track(buttonId, at: Date()) { onEvent(event) }
        }
    }

    /// Plays a haptic; unknown kinds do nothing.
    static func haptic(_ kind: String) {
        switch kind {
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        default: break
        }
    }

    // MARK: WKNavigationDelegate

    /// Allows only the initial load of the page; cancels every other navigation, link taps and frames included.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !loadStarted, action.targetFrame?.isMainFrame == true {
            loadStarted = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    /// The page is on screen: reports `shown` once.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, let event = showing.shown(at: Date()) else { return }
        onEvent(event)
    }

    /// The page failed to load; nothing was shown.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { close() }

    /// The page failed to load; nothing was shown.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { close() }

    /// The web content process ended, leaving a blank window; close it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }

    // MARK: WKUIDelegate

    /// Never opens a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    /// Denies camera and microphone.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: UIScrollViewDelegate

    /// No zooming.
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }
}

/// The overlay's root: reports layout and trait changes, so the page gets a new posture.
final class InAppRootController: UIViewController {
    var layoutChanged: (() -> Void)?

    /// Size changes, rotation included, end in a layout pass.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChanged?()
    }

    /// Trait changes, such as a new size class.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layoutChanged?()
    }
}
#endif
