import Foundation
import Security
import XCTest
@testable import Insomnia

final class LocalSigningPolicyTests: XCTestCase {
    func testDeveloperIDRequirementCompilesAndPinsTeamAppAndDistributionChannel() throws {
        let text = try PowerBrokerPolicy.requirement(forTeam: "ABCDEFGHIJ")
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertTrue(text.contains("identifier \"local.insomnialocal.app\""))
        XCTAssertTrue(text.contains("subject.OU] = \"ABCDEFGHIJ\""))
        XCTAssertTrue(text.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        XCTAssertTrue(text.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
    }
    func testInvalidTeamsCannotInjectRequirementExpressions() {
        for team in ["", "short", "abcdefghij", "ABCDEFGHIJ or true", "\" or true", "ABCDEFGHIJK", "ABCD;EFGHI"] {
            XCTAssertThrowsError(try PowerBrokerPolicy.requirement(forTeam: team))
        }
    }
    func testInstallerAndUninstallerUseSameDeveloperIDMarkers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for script in ["install-local.sh", "uninstall-local.sh"] {
            let source = try String(contentsOf: root.appendingPathComponent("scripts/\(script)"), encoding: .utf8)
            XCTAssertTrue(source.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
            XCTAssertTrue(source.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        }
    }
}
