import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// Downloads an image to a local file whose extension iOS accepts; nil on any failure.
protocol ImageDownloader {
    func download(_ url: URL, completion: @escaping (URL?) -> Void)
}

/// Shows the image of a PushPilot push. Keep one instance in your Notification Service Extension and
/// forward `didReceive(_:withContentHandler:)` and `serviceExtensionTimeWillExpire()` to it.
/// Safe for app extensions: it uses no app-only API.
public final class PushPilotImageAttacher {
    private let downloader: ImageDownloader
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    /// Creates an attacher that downloads over HTTPS with URLSession.
    public convenience init() {
        self.init(downloader: URLSessionImageDownloader())
    }

    /// Creates an attacher with a custom downloader; tests use this.
    init(downloader: ImageDownloader) {
        self.downloader = downloader
    }

    /// Handles a PushPilot push: attaches the https `image_url` image if it downloads, otherwise delivers
    /// the push unchanged, and calls `contentHandler` exactly once. Returns false without calling
    /// `contentHandler` for any other push, so your own code can handle it.
    public func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) -> Bool {
        let content = request.content
        guard content.userInfo["source"] as? String == "pushpilot" else { return false }
        lock.lock()
        self.contentHandler = contentHandler
        original = content
        lock.unlock()
        guard let link = content.userInfo["image_url"] as? String, let url = URL(string: link),
              url.scheme?.lowercased() == "https" else {
            deliver(content)
            return true
        }
        downloader.download(url) { [self] file in
            guard let file,
                  let attachment = try? UNNotificationAttachment(identifier: "pushpilot-image", url: file),
                  let rich = content.mutableCopy() as? UNMutableNotificationContent else {
                return deliver(content)
            }
            rich.attachments = [attachment]
            deliver(rich)
        }
        return true
    }

    /// Delivers the push without its image when iOS is about to stop the extension.
    public func serviceExtensionTimeWillExpire() {
        lock.lock()
        let content = original
        lock.unlock()
        if let content { deliver(content) }
    }

    /// Calls the content handler once, whichever of download and expiry finishes first.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    /// The file extension for a downloaded image: from the response's MIME type, else from the URL.
    /// nil when neither names an image type, since iOS rejects attachments it cannot identify.
    static func fileExtension(url: URL, mimeType: String?) -> String? {
        if let mimeType, let type = UTType(mimeType: mimeType), type.conforms(to: .image) {
            return type.preferredFilenameExtension
        }
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return nil }
        return ext
    }
}

/// Downloads to disk with URLSession, so a large image never sits in the extension's small memory budget.
struct URLSessionImageDownloader: ImageDownloader {
    /// iOS accepts image attachments up to 10 MB.
    static let maxBytes = 10 * 1024 * 1024

    /// Downloads `url`, checks status, type and size, and moves the file to a temporary path with an image extension.
    // shortcut: the size cap is checked after the download finishes; stream with a delegate if huge images become a problem.
    func download(_ url: URL, completion: @escaping (URL?) -> Void) {
        // Under the ~30 s iOS gives the extension, leaving room to deliver.
        let request = URLRequest(url: url, timeoutInterval: 20)
        URLSession.shared.downloadTask(with: request) { file, response, _ in
            guard let file, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let ext = PushPilotImageAttacher.fileExtension(url: url, mimeType: http.mimeType),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxBytes
            else { return completion(nil) }
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            // URLSession deletes its file when this closure returns, so move it now.
            completion((try? FileManager.default.moveItem(at: file, to: target)) != nil ? target : nil)
        }.resume()
    }
}
