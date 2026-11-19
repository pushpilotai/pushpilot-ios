import Foundation

/// The in-app cache on disk and its downloads (IN-APP-SDK.md sections 1 and 2). Safe to use from any thread:
/// it holds no state of its own beyond the folder and the loader.
struct InAppStore {
    /// Loads one GET request; nil on a network error. Tests replace it.
    typealias Loader = (URLRequest) async -> (Data, HTTPURLResponse)?

    let folder: URL
    let load: Loader

    /// The store in Application Support, next to the SDK's state, loading over an ephemeral session.
    static let device = InAppStore(
        folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PushPilot/in-app"),
        load: { request in
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            return (data, http)
        })
    private static let session = URLSession(configuration: .ephemeral)

    // MARK: Disk

    /// The saved cache; empty when there is none or it cannot be read.
    func readCache() -> InAppCache {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("cache.json")),
              let cache = try? JSONDecoder().decode(InAppCache.self, from: data) else { return InAppCache() }
        return cache
    }

    /// Saves the cache index; a failure only means the next launch starts from an older one.
    func writeCache(_ cache: InAppCache) {
        do { try write(JSONEncoder().encode(cache), "cache.json") } catch {
            log.error("Could not save the in-app cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A cached page's HTML, or nil when the file is gone.
    func readPage(_ file: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
    }

    /// Removes a cached page file.
    func deletePage(_ file: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
    }

    /// Writes a file atomically into the in-app folder, which is excluded from backups like the SDK's state.
    private func write(_ data: Data, _ name: String) throws {
        var folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Network

    /// Asks the server which messages this installation may be shown; nil on any failure.
    func fetchList(baseUrl: URL, sdkKey: String, installationId: String) async -> InAppList? {
        guard var parts = URLComponents(url: baseUrl.appendingPathComponent("api/sdk/v1/in-app/"), resolvingAgainstBaseURL: false)
        else { return nil }
        parts.queryItems = [URLQueryItem(name: "installation_id", value: installationId)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(sdkKey, forHTTPHeaderField: "X-SDK-Key")
        // An ephemeral session still caches in memory; without this a running app keeps its first answer.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = await load(request) else { return nil }
        guard response.statusCode == 200 else {
            log.error("In-app fetch failed with HTTP \(response.statusCode)")
            return nil
        }
        return InAppList.decode(data)
    }

    /// Downloads one http(s) file with its media type; nil on any failure.
    func download(_ text: String) async -> (data: Data, mime: String)? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        guard let (data, response) = await load(URLRequest(url: url, timeoutInterval: 30)),
              response.statusCode == 200 else { return nil }
        return (data, response.mimeType ?? "application/octet-stream")
    }

    /// Downloads a message's page (the light one on a slow phone) and every asset, inlines the assets and writes
    /// the page. Returns nil, writing nothing, when any download fails, so the next fetch tries again.
    /// shortcut: a retry downloads every asset again; keep assets as files if pages grow large.
    func cache(_ message: InAppMessage, slow: Bool) async -> InAppCachedPage? {
        let (url, light) = InAppPage.pageURL(message, slow: slow)
        guard let file = InAppPage.cacheFile(id: message.id, version: message.htmlVersion, light: light),
              let page = await download(url), let html = String(data: page.data, encoding: .utf8) else { return nil }
        var assets: [String: (data: Data, mime: String)] = [:]
        for asset in Set(message.assets ?? []) {
            guard let loaded = await download(asset) else { return nil }
            assets[asset] = loaded
        }
        do { try write(Data(InAppPage.inline(html, assets: assets).utf8), file) } catch { return nil }
        return InAppCachedPage(version: message.htmlVersion, light: light, file: file)
    }

    /// Takes a new answer: its messages and origins replace the old ones, and pages of dropped messages or
    /// older versions are removed from the index. Returns the files no longer needed.
    static func apply(_ list: InAppList, to cache: inout InAppCache) -> [String] {
        let current = Dictionary(list.messages.map { ($0.id, $0.htmlVersion) }) { first, _ in first }
        var stale: [String] = []
        for (id, page) in cache.pages where current[id] != page.version {
            stale.append(page.file)
            cache.pages[id] = nil
        }
        cache.messages = list.messages
        cache.allowedOrigins = list.allowedOrigins ?? []
        cache.shown = cache.shown.filter { current[$0.key] != nil }
        return stale.sorted()
    }
}
