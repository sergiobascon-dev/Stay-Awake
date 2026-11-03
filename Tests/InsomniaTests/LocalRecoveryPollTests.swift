import XCTest
@testable import Insomnia

@MainActor
final class LocalRecoveryPollTests: XCTestCase {
    func testLiveLeaseIsProbedUnderRecoveryLockAndNotEnded() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(300)))
        var state = RuntimeState(); state.sleepDisabledByUs = true
        try h.store.saveState(state)
        let manager = h.makeManager()
        let settled = await manager.recoverLocalSessionIfNeeded {
            XCTAssertNotNil(RecoveryLock.held, "Probe must run after the start/end lock is acquired")
        }
        XCTAssertTrue(settled)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"))
    }
    func testAbsentLeaseRecoversUserJournalWithoutResurrectingIt() async throws {
        let h = Harness(); defer { h.home.destroy() }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(300)))
        var state = RuntimeState(); state.sleepDisabledByUs = true; state.lowPowerSetByUs = true
        try h.store.saveState(state)
        let manager = h.makeManager()
        let settled = await manager.recoverLocalSessionIfNeeded { throw LeaseFailure(message: "lease ended") }
        XCTAssertTrue(settled)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"))
        XCTAssertEqual(try h.store.loadState(), .clean)
    }
    func testFailedUserRestoreRemainsPending() async throws {
        let h = Harness(); defer { h.home.destroy() }
        var state = RuntimeState(); state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.throwOn = ["disablesleep 0"]
        let settled = await h.makeManager().recoverLocalSessionIfNeeded { }
        XCTAssertFalse(settled)
        XCTAssertTrue(try h.store.loadState()?.sleepDisabledByUs == true)
    }
}
