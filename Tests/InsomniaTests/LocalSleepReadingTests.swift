import XCTest
@testable import Insomnia
final class LocalSleepReadingTests: XCTestCase {
    func testUnconfiguredSleepOverrideInRealMacListingIsEnabledSleep() {
        let output = "System-wide power settings:\nCurrently in use:\n standby 1\n sleep 1 (sleep prevented by coreaudiod)\n lowpowermode 0\n"
        XCTAssertEqual(PmsetSleepGuard.readEffectiveSleepDisabled(output), false)
    }
    func testExplicitFlagAlwaysWins() {
        for bit in [0, 1] {
            XCTAssertEqual(PmsetSleepGuard.readEffectiveSleepDisabled("System-wide power settings:\n SleepDisabled \(bit)\nCurrently in use:\n sleep 1"), bit == 1)
        }
    }
    func testMalformedOrTruncatedOutputNeverAssumesEnabledSleep() {
        for output in ["", "System-wide power settings:", "Currently in use:\n sleep 1", "System-wide power settings:\nCurrently in use:\n sleep x", "System-wide power settings:\n SleepDisabled unknown\nCurrently in use:\n sleep 1"] {
            XCTAssertNil(PmsetSleepGuard.readEffectiveSleepDisabled(output))
        }
    }
}
