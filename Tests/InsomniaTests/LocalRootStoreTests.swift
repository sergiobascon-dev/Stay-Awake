import XCTest
import Darwin
@testable import Insomnia

final class LocalRootStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("private") }
    private var journal: URL { directory.appendingPathComponent("power-lease.json") }
    private var store: RootLeaseStore { RootLeaseStore(directory: directory, expectedOwner: getuid()) }
    private var lease: PowerLease {
        PowerLease(owner: getuid(), endsAt: Date(timeIntervalSince1970: 1_800_001_000),
            heartbeatAt: Date(timeIntervalSince1970: 1_800_000_000), originalSleepDisabled: false,
            originalLowPower: true, requestedLowPower: false, restoreSleep: true, restoreLowPower: false)
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("local-root-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testDurableRoundTripAndRemoval() throws {
        XCTAssertNil(try store.load())
        try store.save(lease)
        XCTAssertEqual(try store.load(), lease)
        let permissions = try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try store.save(nil)
        XCTAssertNil(try store.load())
    }
    func testSymlinkDirectoryIsRejectedWithoutTouchingTarget() throws {
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(lease))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    func testGroupReadableDirectoryIsRejected() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        XCTAssertThrowsError(try store.save(lease))
    }
    func testSymlinkJournalIsRejectedOnRead() throws {
        _ = try store.load()
        let target = root.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
    }
    func testHardlinkedJournalIsRejected() throws {
        try store.save(lease)
        try FileManager.default.linkItem(at: journal, to: root.appendingPathComponent("alias"))
        XCTAssertThrowsError(try store.load())
    }
    func testWorldReadableJournalIsRejected() throws {
        try store.save(lease)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.path)
        XCTAssertThrowsError(try store.load())
    }
    func testCorruptJournalIsNotTreatedAsClean() throws {
        _ = try store.load()
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        try Data("truncated".utf8).write(to: journal)
        XCTAssertEqual(chmod(journal.path, 0o600), 0)
        XCTAssertThrowsError(try store.load())
    }
    func testExtendedACLIsRejectedEvenWhenUnixModeIsPrivate() throws {
        _ = try store.load()
        let chmodProcess = Process()
        chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProcess.arguments = ["+a", "user:\(String(cString: getpwuid(getuid()).pointee.pw_name)) allow read,readattr,readextattr,readsecurity", directory.path]
        chmodProcess.standardOutput = FileHandle.nullDevice
        chmodProcess.standardError = FileHandle.nullDevice
        try chmodProcess.run()
        chmodProcess.waitUntilExit()
        XCTAssertEqual(chmodProcess.terminationStatus, 0)
        XCTAssertThrowsError(try store.save(lease))
    }
    func testRetirementKeepsDirtyJournalAndRemovesDirectoryOnlyAfterRecovery() throws {
        try store.save(lease)
        XCTAssertThrowsError(try store.removeAfterRecovery())
        XCTAssertEqual(try store.load(), lease)
        try store.save(nil)
        try store.removeAfterRecovery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testFIFOIsRejectedWithoutBlocking() throws {
        _ = try store.load()
        XCTAssertEqual(mkfifo(journal.path, 0o600), 0)
        XCTAssertThrowsError(try store.load())
    }
}
