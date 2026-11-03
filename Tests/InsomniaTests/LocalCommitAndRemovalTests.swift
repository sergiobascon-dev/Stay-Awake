import XCTest
@testable import Insomnia

final class LocalCommitAndRemovalTests: XCTestCase {
    func testFailedServiceQueryIsNotProofOfRemoval() {
        let label = Paths.backstopLabel
        for result in [
            ShellResult(status: 0, stdout: "loaded", stderr: ""),
            ShellResult(status: 1, stdout: "", stderr: "Operation not permitted"),
            ShellResult(status: 113, stdout: "", stderr: "Could not find service \"different.label\" in domain"),
            ShellResult(status: -1, stdout: "", stderr: "launchctl timed out")
        ] { XCTAssertFalse(LocalServiceRemoval.confirmedAbsent(result, label: label)) }
        XCTAssertTrue(LocalServiceRemoval.confirmedAbsent(
            ShellResult(status: 113, stdout: "", stderr: "Could not find service \"\(label)\" in domain for user gui:501"), label: label))
    }
    func testDirectoryCommitFailureIsReportedEvenAfterAtomicPublish() throws {
        let h = TempHome(); defer { h.destroy() }
        let writer = Store(paths: h.paths, synchronizeDirectory: { _ in throw LeaseFailure(message: "injected directory sync failure") })
        XCTAssertThrowsError(try writer.saveState(.clean))
        // The write may be visible, but success must never be reported until
        // the directory entry itself is synchronized.
        XCTAssertEqual(try Store(paths: h.paths).loadState(), .clean)
    }
    func testDeletionRetriesDirectoryCommitEvenWhenNameIsAlreadyGone() throws {
        let h = TempHome(); defer { h.destroy() }
        try Store(paths: h.paths).saveSession(Session(startedAt: Date(), endsAt: Date().addingTimeInterval(300)))
        let calls = Locked(0)
        let fail = Locked(true)
        let writer = Store(paths: h.paths, synchronizeDirectory: { _ in
            calls.value += 1
            if fail.value { throw LeaseFailure(message: "injected directory sync failure") }
        })
        XCTAssertThrowsError(try writer.deleteSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.sessionFile.path))
        fail.value = false
        try writer.deleteSession()
        XCTAssertEqual(calls.value, 2)
    }
}
