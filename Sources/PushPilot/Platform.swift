import Foundation
import Security
import UserNotifications

/// Installation id in the Keychain (`ThisDeviceOnly`, so backups never carry it to another device)
/// and the rest of the state as a JSON file in Application Support.
struct DeviceStorage: Storage {
    private let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ai.pushpilot.sdk",
        kSecAttrAccount as String: "installation_id",
    ]
    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PushPilot")
    }

    /// Reads the id; nil if none is stored, throws if the Keychain is locked or failing.
    func readInstallationId() throws -> String? {
        var query = keychain
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    /// Updates the stored id in place, or adds it if there is none yet.
    func writeInstallationId(_ id: String) throws {
        let data = Data(id.utf8)
        var status = SecItemUpdate(keychain as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = keychain
            item[kSecValueData as String] = data
            // Readable after the first unlock so pushes and background launches can sync.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Reads saved state; nil if there is none or it is unreadable as JSON, throws if the file cannot be read.
    func readState() throws -> State? { try read(State.self, "state.json") }

    /// Writes state; see `write`.
    func writeState(_ state: State) throws { try write(state, "state.json") }

    /// Reads the saved SDK key and server; nil if there are none or they are unreadable.
    func readConfig() throws -> SavedConfig? { try read(SavedConfig.self, "config.json") }

    /// Saves the SDK key and server next to the state.
    func writeConfig(_ config: SavedConfig) throws { try write(config, "config.json") }

    /// Decodes a file in the SDK's folder; nil if it is missing or not valid JSON, throws if it cannot be read.
    private func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let file = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes a file atomically into the SDK's folder, which is excluded from backups so a restore onto
    /// another phone never carries this phone's push token. The flag is on the folder because an atomic
    /// write replaces the file and would drop a flag set on the file itself.
    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        var folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try folder.setResourceValues(values) } catch {
            log.error("Could not exclude state from backup: \(error.localizedDescription, privacy: .public)")
        }
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

/// A Keychain call failed with this OSStatus.
struct KeychainError: Error {
    let status: OSStatus
}

/// POSTs JSON over an ephemeral URLSession (no cookies or cache).
struct URLSessionNetwork: Network {
    let queue: DispatchQueue
    private static let session = URLSession(configuration: .ephemeral)

    /// Sends the request and hands the status, `Retry-After` and body back on the SDK queue.
    func post(_ url: URL, sdkKey: String, body: Data, completion: @escaping (Result<HTTPReply, Error>) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sdkKey, forHTTPHeaderField: "X-SDK-Key")
        request.httpBody = body
        Self.session.dataTask(with: request) { data, response, error in
            let result: Result<HTTPReply, Error>
            if let response = response as? HTTPURLResponse {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                result = .success(HTTPReply(status: response.statusCode, retryAfter: retryAfter, body: data ?? Data()))
            } else {
                result = .failure(error ?? URLError(.badServerResponse))
            }
            queue.async { completion(result) }
        }.resume()
    }
}

/// Wall-clock time and delays on the SDK queue.
struct SystemClock: Clock {
    let queue: DispatchQueue
    var now: Date { Date() }

    /// Runs `work` on the SDK queue after `seconds`.
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Reads the automatic fields from the OS. Never requests notification permission.
struct SystemDeviceInfo: DeviceInfo {
    let queue: DispatchQueue

    /// Reads the permission state, then returns all automatic fields on the SDK queue.
    func collect(_ completion: @escaping ([String: JSONValue]) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            var fields = Self.fields(permission: Self.permission(settings.authorizationStatus))
            fields["apns_environment"] = .string(Self.apnsEnvironment)
            queue.async { completion(fields) }
        }
    }

    /// The APNs host this build's tokens belong to, read from how the running build was signed.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        // App Store and TestFlight builds carry no embedded profile and always use production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url) else { return "production" }
        return apnsEnvironment(profile: profile)
        #endif
    }()

    /// `sandbox` when the profile's `aps-environment` entitlement is `development`, otherwise `production`.
    static func apnsEnvironment(profile: Data) -> String {
        // The profile is a signed CMS envelope around an XML plist; the plist can be cut out as text.
        guard let text = String(data: profile, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return "production" }
        return entitlements["aps-environment"] as? String == "development" ? "sandbox" : "production"
    }

    /// Maps the OS authorisation status to the server's four values.
    static func permission(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .ephemeral: return "granted"
        case .denied: return "denied"
        case .provisional: return "provisional"
        default: return "unknown"
        }
    }

    /// The automatic fields, cut to the server's length limits.
    static func fields(permission: String) -> [String: JSONValue] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return [
            "notification_permission": .string(permission),
            "os_version": .string(String(osVersion.prefix(50))),
            "app_version": .string(String(appVersion.prefix(50))),
            "sdk_version": .string(PushPilot.sdkVersion),
            "device_model": .string(String(modelIdentifier().prefix(100))),
            "locale": .string(String(bcp47(Locale.current).prefix(35))),
            "timezone": .string(TimeZone.current.identifier),
        ]
    }

    /// Hardware model such as `iPhone15,2`; the simulated model on a simulator.
    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The locale as a BCP 47 tag such as `en-US`.
    static func bcp47(_ locale: Locale) -> String {
        if #available(iOS 16, macOS 13, *) { return locale.identifier(.bcp47) }
        // iOS 15: ICU ids are `en_US` or `en_US@calendar=…`; drop keywords and switch the separator.
        let base = locale.identifier.split(separator: "@").first.map(String.init) ?? locale.identifier
        return base.replacingOccurrences(of: "_", with: "-")
    }
}
