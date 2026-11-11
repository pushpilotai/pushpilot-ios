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

final class ImageAttacherTests: XCTestCase {
    let downloader = FakeDownloader()
    lazy var attacher = PushPilotImageAttacher(downloader: downloader)
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

    /// The saved file gets an image extension from the MIME type, else from the URL, else none.
    func testFileExtension() {
        let ext = PushPilotImageAttacher.fileExtension
        XCTAssertEqual(ext(URL(string: "https://x.io/i?id=1")!, "image/png"), "png")
        XCTAssertEqual(ext(URL(string: "https://x.io/i?id=1")!, "image/gif"), "gif")
        XCTAssertEqual(ext(URL(string: "https://x.io/a.JPG")!, "application/octet-stream"), "jpg")
        XCTAssertEqual(ext(URL(string: "https://x.io/a.jpeg")!, nil), "jpeg")
        XCTAssertNil(ext(URL(string: "https://x.io/page.php")!, "text/html"))
        XCTAssertNil(ext(URL(string: "https://x.io/image")!, nil))
    }
}
