import UserNotifications
import XCTest
@testable import PushPilot

final class PushPilotTests: XCTestCase {
    /// Calls before initialize are queued and applied in order once it runs; a second initialize is ignored.
    func testCallsBeforeInitializeAreQueuedAndInitIsIdempotent() throws {
        let storage = FakeStorage(), network = FakeNetwork(), clock = FakeClock()
        var created = 0
        var engine: Engine?
        PushPilot.makeEngine = { key, url in
            created += 1
            let made = try Engine(sdkKey: key, baseUrl: url, storage: storage, network: network, clock: clock, device: FakeDevice())
            engine = made
            return made
        }
        PushPilot.setPushToken(tok1)
        PushPilot.setExternalUserId("user-9")
        PushPilot.queue.sync {}
        XCTAssertNil(engine)
        PushPilot.initialize(sdkKey: "pk_test")
        PushPilot.initialize(sdkKey: "other")
        PushPilot.queue.sync {}
        XCTAssertEqual(created, 1)
        XCTAssertEqual(engine?.state.token, hex1)
        XCTAssertEqual(engine?.state.externalUserId, "user-9")
        PushPilot.queue.sync { clock.advance(Engine.coalesceDelay) }
        XCTAssertEqual(network.all.count, 1)
        XCTAssertEqual(network.all.first?.sdkKey, "pk_test")
    }

    /// The real state file round-trips, and its folder stays excluded from backup across atomic rewrites.
    func testStateFileIsExcludedFromBackup() throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PushPilot")
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = DeviceStorage()
        XCTAssertNil(try storage.readState())
        try storage.writeState(State(token: "tok-1"))
        try storage.writeState(State(token: "tok-2"))
        XCTAssertEqual(try storage.readState()?.token, "tok-2")
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// Only pushes the server marked with source = pushpilot are claimed.
    func testHandleMessage() {
        XCTAssertTrue(PushPilot.handleMessage(["source": "pushpilot", "aps": ["alert": "hi"]]))
        XCTAssertFalse(PushPilot.handleMessage(["source": "other"]))
        XCTAssertFalse(PushPilot.handleMessage(["aps": ["alert": "hi"]]))
    }

    /// OS authorisation states map to the server's four values.
    func testPermissionMapping() {
        XCTAssertEqual(SystemDeviceInfo.permission(.authorized), "granted")
        XCTAssertEqual(SystemDeviceInfo.permission(.ephemeral), "granted")
        XCTAssertEqual(SystemDeviceInfo.permission(.denied), "denied")
        XCTAssertEqual(SystemDeviceInfo.permission(.provisional), "provisional")
        XCTAssertEqual(SystemDeviceInfo.permission(.notDetermined), "unknown")
    }

    /// Automatic fields have the server's names and formats.
    func testAutomaticFields() {
        let fields = SystemDeviceInfo.fields(permission: "unknown")
        XCTAssertEqual(Set(fields.keys), ["notification_permission", "os_version", "app_version", "sdk_version",
                                          "device_model", "locale", "timezone"])
        XCTAssertEqual(fields["sdk_version"], .string(PushPilot.sdkVersion))
        XCTAssertEqual(SystemDeviceInfo.bcp47(Locale(identifier: "en_US")), "en-US")
        XCTAssertEqual(SystemDeviceInfo.bcp47(Locale(identifier: "pt_BR")), "pt-BR")
        XCTAssertEqual(fields["timezone"], .string(TimeZone.current.identifier))
        XCTAssertFalse(SystemDeviceInfo.modelIdentifier().isEmpty)
    }
}
