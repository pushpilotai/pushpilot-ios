import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// Downloads an image to a local file whose extension iOS accepts; nil on any failure.
protocol ImageDownloader {
    func download(_ url: URL, completion: @escaping (URL?) -> Void)
}

/// Reads and replaces the app's notification categories; callbacks may come on any thread.
protocol CategoryStore {
    func categories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void)
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

/// The real categories, shared by the app and its extensions.
struct SystemCategoryStore: CategoryStore {
    /// Reads the registered categories.
    func categories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) {
        UNUserNotificationCenter.current().getNotificationCategories(completionHandler: completion)
    }

    /// Replaces the registered categories.
    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}

/// Adds the image and buttons of a PushPilot push. Keep one instance in your Notification Service
/// Extension and forward `didReceive(_:withContentHandler:)` and `serviceExtensionTimeWillExpire()` to it.
/// Safe for app extensions: it uses no app-only API.
public final class PushPilotServiceExtension {
    private let downloader: ImageDownloader
    private let store: CategoryStore
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// What expiry delivers: the original push, then the push with its buttons once they are set.
    private var best: UNNotificationContent?

    /// Creates a helper that downloads over HTTPS with URLSession and registers buttons with the system.
    public convenience init() {
        self.init(downloader: URLSessionImageDownloader(), categories: SystemCategoryStore())
    }

    /// Creates a helper with custom dependencies; tests use this.
    init(downloader: ImageDownloader, categories: CategoryStore) {
        self.downloader = downloader
        self.store = categories
    }

    /// Handles a PushPilot push: registers its `buttons` as a notification category and attaches its
    /// https `image_url` image, then calls `contentHandler` exactly once. Whatever fails is left out and
    /// the rest is delivered. Returns false without calling `contentHandler` for any other push, so your
    /// own code can handle it.
    public func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) -> Bool {
        let content = request.content
        guard content.userInfo["source"] as? String == "pushpilot" else { return false }
        lock.lock()
        self.contentHandler = contentHandler
        best = content
        lock.unlock()
        guard let rich = content.mutableCopy() as? UNMutableNotificationContent else {
            deliver(content)
            return true
        }
        addButtons(to: rich) { [self] in
            lock.lock()
            best = rich.copy() as? UNNotificationContent ?? content
            lock.unlock()
            addImage(to: rich) { [self] in deliver(rich) }
        }
        return true
    }

    /// Delivers the push without its image (with its buttons if they are ready) when iOS is about to stop the extension.
    public func serviceExtensionTimeWillExpire() {
        lock.lock()
        let content = best
        lock.unlock()
        if let content { deliver(content) }
    }

    /// Registers a category for the push's buttons, keeping the app's own categories, and sets it on `content`.
    // shortcut: PushPilot categories accumulate, one per distinct button set; prune them if apps send many distinct sets.
    private func addButtons(to content: UNMutableNotificationContent, then next: @escaping () -> Void) {
        guard let category = Self.category(for: content.userInfo["buttons"]) else { return next() }
        store.categories { [self] existing in
            if existing.contains(where: { $0.identifier == category.identifier }) {
                content.categoryIdentifier = category.identifier
                return next()
            }
            store.setCategories(existing.union([category]))
            // Reading back waits until the new set is in place, so the push never names a missing category.
            store.categories { registered in
                if registered.contains(where: { $0.identifier == category.identifier }) {
                    content.categoryIdentifier = category.identifier
                }
                next()
            }
        }
    }

    /// Downloads the push's https `image_url` and attaches it to `content`; on failure leaves `content` as it is.
    private func addImage(to content: UNMutableNotificationContent, then next: @escaping () -> Void) {
        guard let link = content.userInfo["image_url"] as? String, let url = URL(string: link),
              url.scheme?.lowercased() == "https" else { return next() }
        downloader.download(url) { file in
            if let file, let attachment = try? UNNotificationAttachment(identifier: "pushpilot-image", url: file) {
                content.attachments = [attachment]
            }
            next()
        }
    }

    /// Calls the content handler once, whichever of the work and expiry finishes first.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    /// The category for a `buttons` value (up to three `{id, label, url?}` objects), or nil if there are none
    /// or any is malformed. A button with a `url` opens the app; one without does not. The identifier is
    /// derived from the buttons, so the same set always reuses one category and a different set gets its own.
    static func category(for buttons: Any?) -> UNNotificationCategory? {
        guard let list = buttons as? [[String: Any]], (1...3).contains(list.count) else { return nil }
        var actions: [UNNotificationAction] = []
        var signature = ""
        for button in list {
            guard let id = button["id"] as? String, !id.isEmpty, let label = button["label"] as? String, !label.isEmpty
            else { return nil }
            let opensApp = (button["url"] as? String).map { !$0.isEmpty } ?? false
            actions.append(UNNotificationAction(identifier: id, title: label, options: opensApp ? [.foreground] : []))
            signature += "\(id)\u{1F}\(label)\u{1F}\(opensApp)\u{1E}"
        }
        let digest = SHA256.hash(data: Data(signature.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return UNNotificationCategory(identifier: "pushpilot.\(digest)", actions: actions, intentIdentifiers: [])
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
                  let ext = PushPilotServiceExtension.fileExtension(url: url, mimeType: http.mimeType),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxBytes
            else { return completion(nil) }
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            // URLSession deletes its file when this closure returns, so move it now.
            completion((try? FileManager.default.moveItem(at: file, to: target)) != nil ? target : nil)
        }.resume()
    }
}
