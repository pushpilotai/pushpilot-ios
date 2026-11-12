import UserNotifications
import XCTest
@testable import PushPilotNotificationService

/// Records requested URLs and finishes each download when the test says so.
final class FakeDownloader: ImageDownloader {
    var requested: [URL] = []
    private var pending: [(URL?) -> Void] = []

    /// Records the URL and waits for `finish`.
    func download(_ url: URL, completion: @escaping (URL?) -> Void) {
        requested.append(url)
        pending.append(completion)
    }

    /// Completes the oldest download with a real 1×1 PNG, or with nil for a failure.
    func finish(succeeding: Bool) throws {
        var file: URL?
        if succeeding {
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try XCTUnwrap(Data(base64Encoded: png)).write(to: url)
            file = url
        }
        pending.removeFirst()(file)
    }
}

/// In-memory notification categories; can refuse to keep what is set, like a failing system call.
final class FakeCategoryStore: CategoryStore {
    var registered: Set<UNNotificationCategory> = []
    var dropsWrites = false
    /// Returns the registered categories.
    func categories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) { completion(registered) }
    /// Replaces the registered categories unless writes are dropped.
    func setCategories(_ categories: Set<UNNotificationCategory>) { if !dropsWrites { registered = categories } }
}

final class ServiceExtensionTests: XCTestCase {
    let downloader = FakeDownloader()
    let store = FakeCategoryStore()
    lazy var attacher = PushPilotServiceExtension(downloader: downloader, categories: store)
    let twoButtons: [[String: Any]] = [
        ["id": "track", "label": "ट्रैक करें", "url": "https://example.com/track"],
        ["id": "later", "label": "لاحقاً"],
    ]
    var delivered: [UNNotificationContent] = []

    /// A notification request with the given custom keys and a title.
    func request(_ userInfo: [AnyHashable: Any]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Sale"
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: "n1", content: content, trigger: nil)
    }

    /// Forwards a request the way the extension does and records what is delivered.
    func receive(_ userInfo: [AnyHashable: Any]) -> Bool {
        attacher.didReceive(request(userInfo)) { [self] in delivered.append($0) }
    }

    /// A PushPilot push with an https image gets the downloaded image attached.
    func testAttachesTheImageOnSuccess() throws {
        XCTAssertTrue(receive(["source": "pushpilot", "image_url": "https://cdn.example.com/a.png"]))
        XCTAssertEqual(downloader.requested, [URL(string: "https://cdn.example.com/a.png")!])
        XCTAssertTrue(delivered.isEmpty, "waits for the download")
        try downloader.finish(succeeding: true)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.attachments.count, 1)
        XCTAssertEqual(delivered.first?.title, "Sale")
    }

    /// A failed download delivers the original content.
    func testDeliversTheOriginalWhenTheDownloadFails() throws {
        XCTAssertTrue(receive(["source": "pushpilot", "image_url": "https://cdn.example.com/a.png"]))
        try downloader.finish(succeeding: false)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.attachments.count, 0)
        XCTAssertEqual(delivered.first?.title, "Sale")
    }

    /// On expiry the original is delivered once, and a late download does not deliver again.
    func testExpiryDeliversTheOriginalOnce() throws {
        XCTAssertTrue(receive(["source": "pushpilot", "image_url": "https://cdn.example.com/a.png"]))
        attacher.serviceExtensionTimeWillExpire()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.attachments.count, 0)
        try downloader.finish(succeeding: true)
        XCTAssertEqual(delivered.count, 1)
    }

    /// Pushes from elsewhere are left to the caller: not handled, not delivered, nothing downloaded.
    func testIgnoresPushesNotFromPushPilot() {
        XCTAssertFalse(receive(["source": "other", "image_url": "https://cdn.example.com/a.png"]))
        XCTAssertFalse(receive(["aps": ["alert": "hi"]]))
        attacher.serviceExtensionTimeWillExpire()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(downloader.requested.isEmpty)
    }

    /// Only https image URLs are fetched; anything else delivers the push unchanged at once.
    func testRejectsNonHttpsImageUrls() {
        for link in ["http://cdn.example.com/a.png", "file:///etc/hosts", "not a url", ""] {
            delivered = []
            XCTAssertTrue(receive(["source": "pushpilot", "image_url": link]), link)
            XCTAssertEqual(delivered.count, 1, link)
            XCTAssertEqual(delivered.first?.attachments.count, 0, link)
        }
        XCTAssertTrue(receive(["source": "pushpilot"]))
        XCTAssertTrue(downloader.requested.isEmpty)
    }

    /// The same buttons always give the same category id; any change in id, label or link gives another.
    func testCategoryIdentifierIsStablePerButtonSet() throws {
        let category = try XCTUnwrap(PushPilotServiceExtension.category(for: twoButtons))
        XCTAssertEqual(PushPilotServiceExtension.category(for: twoButtons)?.identifier, category.identifier)
        XCTAssertTrue(category.identifier.hasPrefix("pushpilot."))
        var relabelled = twoButtons
        relabelled[1]["label"] = "Later"
        var linked = twoButtons
        linked[1]["url"] = "https://example.com/later"
        for other in [relabelled, Array(twoButtons.prefix(1)), Array(twoButtons.reversed()), linked] {
            XCTAssertNotEqual(PushPilotServiceExtension.category(for: other)?.identifier, category.identifier)
        }
    }

    /// A button with a url opens the app; one without stays in the background. Labels keep their script.
    func testButtonsBecomeActions() throws {
        let actions = try XCTUnwrap(PushPilotServiceExtension.category(for: twoButtons)).actions
        XCTAssertEqual(actions.map(\.identifier), ["track", "later"])
        XCTAssertEqual(actions.map(\.title), ["ट्रैक करें", "لاحقاً"])
        XCTAssertTrue(actions[0].options.contains(.foreground))
        XCTAssertFalse(actions[1].options.contains(.foreground))
    }

    /// Missing, empty, over three, or malformed buttons give no category.
    func testMalformedButtonsGiveNoCategory() {
        let four = Array(repeating: ["id": "a", "label": "A"], count: 4)
        for bad: Any? in [nil, [[String: Any]](), four, [["id": "a"]], [["label": "A"]], "track", [["id": "", "label": "A"]]] {
            XCTAssertNil(PushPilotServiceExtension.category(for: bad))
        }
    }

    /// Delivery registers the button category next to the app's own and sets it on the push.
    func testRegistersButtonsAndKeepsTheAppsCategories() throws {
        let appCategory = UNNotificationCategory(identifier: "app.reply", actions: [], intentIdentifiers: [])
        store.registered = [appCategory]
        XCTAssertTrue(receive(["source": "pushpilot", "buttons": twoButtons]))
        let expected = try XCTUnwrap(PushPilotServiceExtension.category(for: twoButtons)).identifier
        XCTAssertEqual(delivered.first?.categoryIdentifier, expected)
        XCTAssertEqual(Set(store.registered.map(\.identifier)), ["app.reply", expected])
        // The same buttons again reuse the category instead of adding another.
        delivered = []
        XCTAssertTrue(receive(["source": "pushpilot", "buttons": twoButtons]))
        XCTAssertEqual(delivered.first?.categoryIdentifier, expected)
        XCTAssertEqual(store.registered.count, 2)
    }

    /// Buttons and image together: both end up on the push; expiry during the download keeps the buttons.
    func testButtonsAndImageTogether() throws {
        XCTAssertTrue(receive(["source": "pushpilot", "buttons": twoButtons, "image_url": "https://cdn.example.com/a.png"]))
        try downloader.finish(succeeding: true)
        XCTAssertEqual(delivered.first?.attachments.count, 1)
        XCTAssertFalse(delivered.first?.categoryIdentifier.isEmpty ?? true)
        delivered = []
        XCTAssertTrue(receive(["source": "pushpilot", "buttons": twoButtons, "image_url": "https://cdn.example.com/a.png"]))
        attacher.serviceExtensionTimeWillExpire()
        XCTAssertEqual(delivered.first?.attachments.count, 0)
        XCTAssertFalse(delivered.first?.categoryIdentifier.isEmpty ?? true)
    }

    /// If the category does not register, the push is delivered without buttons.
    func testDeliversWithoutButtonsWhenRegistrationFails() {
        store.dropsWrites = true
        XCTAssertTrue(receive(["source": "pushpilot", "buttons": twoButtons]))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.categoryIdentifier, "")
        XCTAssertEqual(delivered.first?.title, "Sale")
    }

    /// The saved file gets an image extension from the MIME type, else from the URL, else none.
    func testFileExtension() {
        let ext = PushPilotServiceExtension.fileExtension
        XCTAssertEqual(ext(URL(string: "https://x.io/i?id=1")!, "image/png"), "png")
        XCTAssertEqual(ext(URL(string: "https://x.io/i?id=1")!, "image/gif"), "gif")
        XCTAssertEqual(ext(URL(string: "https://x.io/a.JPG")!, "application/octet-stream"), "jpg")
        XCTAssertEqual(ext(URL(string: "https://x.io/a.jpeg")!, nil), "jpeg")
        XCTAssertNil(ext(URL(string: "https://x.io/page.php")!, "text/html"))
        XCTAssertNil(ext(URL(string: "https://x.io/image")!, nil))
    }
}
