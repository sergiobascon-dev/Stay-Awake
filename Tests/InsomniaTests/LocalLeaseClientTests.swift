import XCTest
@testable import Insomnia

@MainActor
final class LocalLeaseClientTests: XCTestCase {
    func testRenewalFailureNotifiesUIOnceAndStopsRenewing() async throws {
        let home = TempHome(); defer { home.destroy() }
        try Store(paths: home.paths).saveSession(Session(startedAt: Date(), endsAt: Date().addingTimeInterval(300)))
        let calls = Locked<[String]>([])
        let failures = Locked(0)
        let client = PowerLeaseClient(renewalInterval: .milliseconds(10), send: { action, _ in
            calls.value.append(action)
            if action == "renew" { throw LeaseFailure(message: "service ended lease") }
        }, onFailure: { failures.value += 1 })
        try await client.begin(paths: home.paths)
        for _ in 0..<100 where failures.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(failures.value, 1)
        XCTAssertEqual(calls.value.filter { $0 == "renew" }.count, 1)
        try await client.end()
    }
    func testMissingSessionAfterSupervisorRestoreNotifiesUI() async throws {
        let home = TempHome(); defer { home.destroy() }
        let store = Store(paths: home.paths)
        try store.saveSession(Session(startedAt: Date(), endsAt: Date().addingTimeInterval(300)))
        let failures = Locked(0)
        let client = PowerLeaseClient(renewalInterval: .milliseconds(10), send: { _, _ in }, onFailure: { failures.value += 1 })
        try await client.begin(paths: home.paths)
        try store.deleteSession()
        for _ in 0..<100 where failures.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(failures.value, 1)
        try await client.end()
    }
    func testUnresponsiveInterfaceCannotRenewAndLateHealthReplyCannotUndoEnd() async throws {
        let home = TempHome(); defer { home.destroy() }
        try Store(paths: home.paths).saveSession(Session(startedAt: Date(), endsAt: Date().addingTimeInterval(300), isPermanent: true))
        let actions = Locked<[String]>([])
        let gate = AsyncGate()
        let client = PowerLeaseClient(renewalInterval: .milliseconds(10), send: { action, _ in
            actions.value.append(action)
        }, onFailure: {}, checkResponsiveness: { await gate.wait() })
        try await client.begin(paths: home.paths)
        await gate.waitUntilStarted()
        XCTAssertEqual(actions.value, ["begin"], "A stuck interface must not renew a permanent lease")
        try await client.end()
        await gate.open()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(actions.value, ["begin", "release"], "A late responsiveness result must not renew an ended lease")
    }

    func testNormalExpiryAfterSupervisorCleanupStopsWithoutFalseFailure() async throws {
        let home = TempHome(); defer { home.destroy() }
        let store = Store(paths: home.paths)
        let now = Date()
        let time = Locked(now)
        try store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(60)))
        let failures = Locked(0)
        let calls = Locked<[String]>([])
        let gate = AsyncGate()
        let client = PowerLeaseClient(renewalInterval: .milliseconds(10), send: { action, _ in calls.value.append(action) },
            onFailure: { failures.value += 1 }, checkResponsiveness: { await gate.wait() }, clock: { time.value })
        try await client.begin(paths: home.paths)
        await gate.waitUntilStarted()
        time.value = now.addingTimeInterval(61)
        try store.deleteSession()
        await gate.open()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(calls.value, ["begin"], "Normal expiry cannot renew or report recovery failure")
        await client.cancelRenewal()
    }

    func testMissingPermanentSessionIsStillReportedAsFailure() async throws {
        let home = TempHome(); defer { home.destroy() }
        let store = Store(paths: home.paths)
        try store.saveSession(Session(startedAt: Date().addingTimeInterval(-600), endsAt: Date().addingTimeInterval(-300), isPermanent: true))
        let failures = Locked(0)
        let client = PowerLeaseClient(renewalInterval: .milliseconds(10), send: { _, _ in }, onFailure: { failures.value += 1 })
        try await client.begin(paths: home.paths)
        try store.deleteSession()
        for _ in 0..<100 where failures.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(failures.value, 1)
        await client.cancelRenewal()
    }

    func testManagerEndCancelsHeartbeatWhenExternalRecoveryAlreadyClearedFlags() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let failures = Locked(0)
        let cancellations = Locked(0)
        let gate = AsyncGate()
        let client = PowerLeaseClient(renewalInterval: .milliseconds(10), send: { _, _ in },
            onFailure: { failures.value += 1 }, checkResponsiveness: { await gate.wait() })
        let guardFixture = RenewalGuardFixture(base: h.guardFake, client: client, paths: h.home.paths, cancellations: cancellations)
        let manager = h.makeManager(sleepGuard: guardFixture)
        await manager.start(duration: 300)
        await gate.waitUntilStarted()
        h.guardFake.sleepDisabled = false
        try h.store.saveState(.clean)
        try h.store.deleteSession()
        await manager.end(reason: .user)
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(cancellations.value, 0)
        XCTAssertEqual(failures.value, 0, "An already restored journal must not leave a live heartbeat")
        XCTAssertNil(manager.session)
        await client.cancelRenewal()
    }

}

private struct RenewalGuardFixture: SleepGuarding {
    let base: FakeSleepGuard
    let client: PowerLeaseClient
    let paths: Paths
    let cancellations: Locked<Int>
    func cancelRenewal() async { cancellations.value += 1; await client.cancelRenewal() }
    func setSleepDisabled(_ disabled: Bool) async throws {
        try await base.setSleepDisabled(disabled)
        if disabled { try await client.begin(paths: paths) }
        else { try await client.end() }
    }
    func isSleepDisabled() async throws -> Bool { try await base.isSleepDisabled() }
    func setLowPowerMode(_ on: Bool) async throws { try await base.setLowPowerMode(on) }
    func isLowPowerModeOn() async throws -> Bool { try await base.isLowPowerModeOn() }
}
