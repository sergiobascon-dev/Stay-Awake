import XCTest
@testable import Insomnia

private final class LeaseFixture: LeasePowerSystem, LeasePersistence {
    var sleep = false
    var low = false
    var disk: PowerLease?
    var calls: [String] = []
    var refuseSave = false
    var refuseSleepRestore = false
    var ignoreSleepRestore = false
    var refuseLowRestore = false
    var ignoreLowWrite = false
    var refuseSleepRead = false
    func readSleep() throws -> Bool {
        if refuseSleepRead { throw LeaseFailure(message: "injected sleep read failure") }
        return sleep
    }
    func readLowPower() throws -> Bool { low }
    func writeSleep(_ value: Bool) throws {
        calls.append("sleep:\(value)")
        XCTAssertNotNil(disk, "Every mutation must have a recovery record first")
        if !value && refuseSleepRestore { throw LeaseFailure(message: "injected sleep failure") }
        if !value && ignoreSleepRestore { return }
        sleep = value
    }
    func writeLowPower(_ value: Bool) throws {
        calls.append("low:\(value)")
        XCTAssertNotNil(disk)
        if !value && refuseLowRestore { throw LeaseFailure(message: "injected low-power failure") }
        if !ignoreLowWrite { low = value }
    }
    func load() throws -> PowerLease? { disk }
    func save(_ lease: PowerLease?) throws {
        if refuseSave { throw LeaseFailure(message: "injected disk failure") }
        disk = lease
    }
}

final class LocalPowerLeaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func start(_ f: LeaseFixture) throws -> PowerLeaseEngine {
        let engine = try PowerLeaseEngine(system: f, persistence: f)
        try engine.renew(owner: 501, until: now.addingTimeInterval(3600), now: now)
        return engine
    }
    private func tick(_ engine: PowerLeaseEngine, at offset: Double = 1, battery: Int? = 80,
                      ac: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) throws {
        try engine.tick(now: now.addingTimeInterval(offset), battery: battery, hasBattery: true, onAC: ac, thermal: thermal)
    }
    func testJournalPrecedesEveryMutationAndNormalEndRestoresBaseline() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try engine.lowPower(owner: 501, enabled: true)
        XCTAssertTrue(f.sleep); XCTAssertTrue(f.low)
        try engine.release(owner: 501)
        XCTAssertFalse(f.sleep); XCTAssertFalse(f.low); XCTAssertNil(f.disk)
    }
    func testExistingLowPowerPreferenceIsNeverDisabled() throws {
        let f = LeaseFixture(); f.low = true
        let engine = try start(f)
        try engine.lowPower(owner: 501, enabled: true)
        try engine.lowPower(owner: 501, enabled: false)
        try engine.release(owner: 501)
        XCTAssertTrue(f.low); XCTAssertFalse(f.calls.contains("low:false"))
    }
    func testForeignSleepSettingRefusesWithoutMutation() throws {
        let f = LeaseFixture(); f.sleep = true
        XCTAssertThrowsError(try start(f)); XCTAssertTrue(f.calls.isEmpty); XCTAssertNil(f.disk)
    }
    func testDiskFailurePreventsFirstMutation() throws {
        let f = LeaseFixture(); f.refuseSave = true
        XCTAssertThrowsError(try start(f)); XCTAssertTrue(f.calls.isEmpty)
    }
    func testDeadUILeaseExpiresAtNinetySeconds() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try tick(engine, at: 89); XCTAssertTrue(f.sleep)
        try tick(engine, at: 90); XCTAssertFalse(f.sleep); XCTAssertNil(f.disk)
    }
    func testHeartbeatExtendsLivenessAndSessionExtension() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try engine.renew(owner: 501, until: now.addingTimeInterval(7200), now: now.addingTimeInterval(80))
        try tick(engine, at: 100); XCTAssertTrue(f.sleep)
        XCTAssertEqual(f.disk?.endsAt, now.addingTimeInterval(7200))
    }
    func testOverdueHeartbeatCannotResurrectLease() throws {
        let f = LeaseFixture(); let engine = try start(f)
        XCTAssertThrowsError(try engine.renew(owner: 501, until: now.addingTimeInterval(7200), now: now.addingTimeInterval(91)))
        XCTAssertFalse(f.sleep); XCTAssertNil(f.disk)
    }
    func testDeadlineEndsEvenWithFreshHeartbeat() throws {
        let f = LeaseFixture(); let engine = try PowerLeaseEngine(system: f, persistence: f)
        try engine.renew(owner: 501, until: now.addingTimeInterval(20), now: now)
        try tick(engine, at: 20); XCTAssertFalse(f.sleep)
    }
    func testSecondUserCannotRenewReleaseOrChangePower() throws {
        let f = LeaseFixture(); let engine = try start(f)
        XCTAssertThrowsError(try engine.renew(owner: 502, until: now.addingTimeInterval(60), now: now))
        XCTAssertThrowsError(try engine.lowPower(owner: 502, enabled: true))
        XCTAssertThrowsError(try engine.release(owner: 502)); XCTAssertTrue(f.sleep)
    }
    func testFailedRestoreKeepsJournalAndRetries() throws {
        let f = LeaseFixture(); let engine = try start(f)
        f.refuseSleepRestore = true
        XCTAssertThrowsError(try engine.release(owner: 501))
        XCTAssertTrue(f.disk?.restoreSleep == true); XCTAssertTrue(engine.recovering)
        f.refuseSleepRestore = false
        try tick(engine); XCTAssertNil(f.disk); XCTAssertFalse(f.sleep)
    }
    func testExitZeroWithoutRestoreReadbackKeepsJournal() throws {
        let f = LeaseFixture(); let engine = try start(f)
        f.ignoreSleepRestore = true
        XCTAssertThrowsError(try engine.release(owner: 501))
        XCTAssertTrue(f.disk?.restoreSleep == true)
    }
    func testFailureOfOneUndoDoesNotSkipOtherUndo() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try engine.lowPower(owner: 501, enabled: true)
        f.refuseSleepRestore = true
        XCTAssertThrowsError(try engine.release(owner: 501))
        XCTAssertFalse(f.low); XCTAssertTrue(f.disk?.restoreLowPower == false)
        XCTAssertTrue(f.disk?.restoreSleep == true)
    }
    func testRestartRestoresInsteadOfResumingSession() throws {
        let f = LeaseFixture(); _ = try start(f)
        let restarted = try PowerLeaseEngine(system: f, persistence: f)
        XCTAssertThrowsError(try restarted.renew(owner: 501, until: now.addingTimeInterval(60), now: now))
        try tick(restarted); XCTAssertNil(f.disk); XCTAssertFalse(f.sleep)
    }
    func testCriticalHeatEndsIndependentOfUI() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try tick(engine, thermal: .critical); XCTAssertNil(f.disk); XCTAssertFalse(f.sleep)
    }
    func testLowBatteryEndsIndependentOfUI() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try tick(engine, battery: 10); XCTAssertNil(f.disk)
    }
    func testOneUnreadableBatteryToleratedTwoEndSession() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try tick(engine, battery: nil); XCTAssertTrue(f.sleep)
        try tick(engine, at: 6, battery: nil); XCTAssertFalse(f.sleep)
    }
    func testACPowerDoesNotEndOnUnreadableOrLowBattery() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try tick(engine, battery: nil, ac: true)
        try tick(engine, at: 6, battery: 1, ac: true); XCTAssertTrue(f.sleep)
    }
    func testSeriousHeatAndLowBatteryEnableLowPower() throws {
        for thermal in [ProcessInfo.ThermalState.serious, .nominal] {
            let f = LeaseFixture(); let engine = try start(f)
            try tick(engine, battery: thermal == .nominal ? 40 : 80, thermal: thermal)
            XCTAssertTrue(f.low)
        }
    }
    func testInvalidDeadlinesNeverChangeSettings() throws {
        for seconds in [-1.0, 0, .infinity, .nan, PowerLeaseEngine.maximumDuration + 1] {
            let f = LeaseFixture(); let engine = try PowerLeaseEngine(system: f, persistence: f)
            XCTAssertThrowsError(try engine.renew(owner: 501, until: now.addingTimeInterval(seconds), now: now))
            XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testClockRollbackEndsSessionConservatively() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try tick(engine, at: -10); XCTAssertFalse(f.sleep)
    }
    func testExternalResetOfSleepEndsLeaseInsteadOfFightingAnotherTool() throws {
        let f = LeaseFixture(); let engine = try start(f)
        f.sleep = false
        try tick(engine)
        XCTAssertNil(f.disk); XCTAssertNil(engine.lease)
    }
    func testLateRenewCannotRecreateReleasedLease() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try engine.release(owner: 501)
        XCTAssertThrowsError(try engine.renew(owner: 501, until: now.addingTimeInterval(3600), now: now, allowNew: false))
        XCTAssertFalse(f.sleep); XCTAssertNil(f.disk)
    }
    func testRepeatedSafetyFloorWritesLowPowerOnlyOnce() throws {
        let f = LeaseFixture(); let engine = try start(f)
        for offset in [1.0, 6, 11] { try tick(engine, at: offset, thermal: .serious) }
        XCTAssertEqual(f.calls.filter { $0 == "low:true" }.count, 1)
    }
    func testOriginallyEnabledLowPowerIsReassertedAndVerifiedWhenNeeded() throws {
        let f = LeaseFixture(); f.low = true
        let engine = try start(f)
        f.low = false
        try engine.lowPower(owner: 501, enabled: true)
        XCTAssertTrue(f.low)
        XCTAssertTrue(f.disk?.restoreLowPower == true)
        try engine.release(owner: 501)
        XCTAssertTrue(f.low)
    }
    func testSilentLowPowerFailureWithOriginalModeOnRemainsJournaled() throws {
        let f = LeaseFixture(); f.low = true
        let engine = try start(f)
        f.low = false; f.ignoreLowWrite = true
        XCTAssertThrowsError(try engine.lowPower(owner: 501, enabled: true))
        XCTAssertTrue(f.disk?.restoreLowPower == true)
    }
    func testOffRequestLeavesUnclaimedForeignLowPowerPreferenceAlone() throws {
        let f = LeaseFixture(); let engine = try start(f)
        f.low = true
        try engine.lowPower(owner: 501, enabled: false)
        XCTAssertTrue(f.low)
        XCTAssertFalse(f.calls.contains("low:false"))
        try engine.release(owner: 501)
        XCTAssertTrue(f.low)
    }
    func testUnreadableSleepStateEntersRecoveryAndRefusesRenewal() throws {
        let f = LeaseFixture(); let engine = try start(f)
        f.refuseSleepRead = true
        XCTAssertThrowsError(try tick(engine))
        XCTAssertTrue(engine.recovering)
        XCTAssertNotNil(f.disk)
        XCTAssertThrowsError(try engine.renew(owner: 501, until: now.addingTimeInterval(300), now: now.addingTimeInterval(2)))
        f.refuseSleepRead = false
        try tick(engine, at: 3)
        XCTAssertNil(f.disk)
    }
    func testRenewalCannotHideClockRollbackBeforeTheSupervisorTick() throws {
        let f = LeaseFixture(); let engine = try start(f)
        XCTAssertThrowsError(try engine.renew(owner: 501, until: now.addingTimeInterval(3600), now: now.addingTimeInterval(-10)))
        XCTAssertNil(f.disk)
        XCTAssertFalse(f.sleep)
    }
    func testCompletedLowPowerUndoDoesNotOverwriteALaterUserPreference() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try engine.lowPower(owner: 501, enabled: true)
        try engine.releaseLowPowerRequest(owner: 501, safetyRequiresLow: false)
        XCTAssertFalse(f.low)
        XCTAssertFalse(f.disk?.restoreLowPower == true)
        f.low = true
        try engine.release(owner: 501)
        XCTAssertTrue(f.low)
    }
    func testMandatoryLowPowerIsNeverReportedAsSuccessfullyDisabled() throws {
        let f = LeaseFixture(); let engine = try start(f)
        XCTAssertThrowsError(try engine.releaseLowPowerRequest(owner: 501, safetyRequiresLow: true))
        XCTAssertTrue(f.low)
        XCTAssertTrue(f.disk?.restoreLowPower == true)
    }
    func testNoMandatoryLowPowerClaimOutsideASession() throws {
        let f = LeaseFixture(); let engine = try PowerLeaseEngine(system: f, persistence: f)
        try engine.releaseLowPowerRequest(owner: 501, safetyRequiresLow: true)
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertNil(f.disk)
    }
    func testReleaseIsIdempotent() throws {
        let f = LeaseFixture(); let engine = try start(f)
        try engine.release(owner: 501); let calls = f.calls
        try engine.release(owner: 501); XCTAssertEqual(f.calls, calls)
    }
}
