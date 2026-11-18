import ActivityKit
import XCTest
@testable import PushPilot

@available(iOS 17.2, *)
final class LiveDismissTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A swipe before the end is the person's; an end seen, or a removal past the stale date, is the system's.
    func testOnlyADismissalBeforeTheEndIsTheUsers() {
        let later = now.addingTimeInterval(600), earlier = now.addingTimeInterval(-90)
        XCTAssertTrue(LiveObserver.userDismissed(.dismissed, ended: false, staleDate: later, now: now))
        XCTAssertTrue(LiveObserver.userDismissed(.dismissed, ended: false, staleDate: nil, now: now))
        XCTAssertFalse(LiveObserver.userDismissed(.dismissed, ended: true, staleDate: later, now: now))
        XCTAssertFalse(LiveObserver.userDismissed(.dismissed, ended: false, staleDate: earlier, now: now))
        XCTAssertFalse(LiveObserver.userDismissed(.ended, ended: false, staleDate: later, now: now))
        XCTAssertFalse(LiveObserver.userDismissed(.active, ended: false, staleDate: later, now: now))
    }
}
