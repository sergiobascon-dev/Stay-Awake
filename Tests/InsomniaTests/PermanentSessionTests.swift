import AppKit
import XCTest
@testable import Insomnia

@MainActor
final class PermanentSessionTests: XCTestCase {
    func testPermanentStartShowsInfinityWithoutDeadlineOrRedrawTimer() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.startPermanently()
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.session?.isPermanent == true)
        XCTAssertEqual(manager.countdownText, "∞")
        XCTAssertEqual(manager.remainingText, "Permanente")
        XCTAssertNil(manager.scheduledDeadline)
        XCTAssertFalse(manager.countdownTimerArmed)
        XCTAssertTrue(try h.store.loadSession()?.isPermanent == true)
        await manager.end(reason: .user)
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(try h.store.loadState(), .clean)
    }
    func testPermanentSessionDoesNotExpireByUserTimerAndCannotBeExtended() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.startPermanently()
        let before = try XCTUnwrap(manager.session)
        XCTAssertFalse(before.isExpired(at: before.endsAt.addingTimeInterval(365 * 86400)))
        await manager.extend(by: 3600)
        XCTAssertEqual(manager.session, before)
        manager.pauseCountdown(); manager.resumeCountdown()
        XCTAssertFalse(manager.countdownTimerArmed)
        await manager.end(reason: .user)
    }
    func testPermanentModeStillEndsForSafetyAndRestores() async throws {
        for reason in [EndReason.batteryFloor, .thermalCritical, .quit, .recoveryUnavailable] {
            let h = Harness(); defer { h.home.destroy() }
            let manager = h.makeManager()
            await manager.startPermanently()
            await manager.end(reason: reason)
            XCTAssertFalse(manager.isActive)
            XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"))
        }
    }
    func testPermanentLeaseIsAlwaysSixtySecondsAndTimedLeaseKeepsDeadline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(startedAt: now, endsAt: now.addingTimeInterval(86400), isPermanent: true)
        XCTAssertEqual(session.powerLeaseDeadline(at: now).timeIntervalSince(now), 60)
        XCTAssertEqual(session.powerLeaseDeadline(at: now.addingTimeInterval(30)).timeIntervalSince(now), 90)
        var timed = session; timed.isPermanent = false
        XCTAssertEqual(timed.powerLeaseDeadline(at: now), timed.endsAt)
    }
    func testLegacyAndPermanentPersistenceRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = Session(startedAt: now, endsAt: now.addingTimeInterval(60))
        let legacy = try Store.makeEncoder().encode(old)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("isPermanent"))
        XCTAssertFalse(try Store.makeDecoder().decode(Session.self, from: legacy).isPermanent)
        var permanent = old; permanent.isPermanent = true
        XCTAssertEqual(try Store.makeDecoder().decode(Session.self, from: Store.makeEncoder().encode(permanent)), permanent)
    }
    func testMenuOffersTimedCustomAndPermanentActionsOnlyWhileIdle() {
        let idle = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil, sessionControls: true)
        XCTAssertEqual(idle.filter { if case .startTimed = $0.kind { return true }; return false }.count, 5)
        XCTAssertTrue(idle.contains { $0.kind == .customDuration })
        XCTAssertTrue(idle.contains { $0.kind == .startPermanent })
        let running = StatusMenu.items(sessionActive: true, sleepHeld: true, machine: nil, actions: nil, throttledBrowsers: [], error: nil, recoveryAvailable: true, sessionControls: true, permanentSession: true)
        XCTAssertFalse(running.contains { $0.kind == .startPermanent })
        XCTAssertTrue(running.contains { $0.kind == .restoreNow })
        XCTAssertTrue(running.contains { $0.title.contains("Permanente") })
    }
    func testPendingAndConfirmedCountdownHaveTheSameWidth() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        let model = MenuBarModel()
        model.phase = .starting
        model.pendingCountdown = "1:00:00"
        func width() -> CGFloat {
            let view = StatusRootView(model: model, manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in })
            return StatusItemController.makeHostingView(view).fittingSize.width
        }
        let pendingWidth = width()
        await manager.start(duration: 3600)
        model.phase = .running
        model.pendingCountdown = nil
        XCTAssertEqual(width(), pendingWidth, accuracy: 0.01)
        await manager.end(reason: .user)
    }

}
