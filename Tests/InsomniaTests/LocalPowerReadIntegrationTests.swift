import XCTest
@testable import Insomnia

final class LocalPowerReadIntegrationTests: XCTestCase {
    func testReadOnlyPowerCommandMatchesLiveReaderWithoutChangingSettings() async throws {
        let reader = PmsetSleepGuard()
        let before = try await reader.isSleepDisabled()
        let throughServiceCommandRunner = try RootPowerSystem().readSleep()
        let after = try await reader.isSleepDisabled()
        XCTAssertEqual(throughServiceCommandRunner, before)
        XCTAssertEqual(after, before)
    }
}
