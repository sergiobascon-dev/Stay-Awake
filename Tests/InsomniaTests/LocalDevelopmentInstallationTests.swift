import Foundation
import Security
import XCTest
import Darwin
@testable import Insomnia

final class LocalDevelopmentInstallationTests: XCTestCase {
    private var root: URL!
    private var resource: URL { root.appendingPathComponent("resource") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("local-install-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try Data("sealed".utf8).write(to: resource)
        XCTAssertEqual(chmod(resource.path, 0o644), 0)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func validate() throws {
        try LocalDevelopmentInstallation.validateTree(bundle: root, expectedOwner: getuid(), checkAncestors: false)
    }
    func testProtectedTreePasses() throws { try validate() }
    func testWritableResourceFails() throws {
        XCTAssertEqual(chmod(resource.path, 0o664), 0)
        XCTAssertThrowsError(try validate())
    }
    func testWritableSubdirectoryFails() throws {
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(sub.path, 0o777), 0)
        XCTAssertThrowsError(try validate())
    }
    func testSymlinkFails() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: resource)
        XCTAssertThrowsError(try validate())
    }
    func testHardlinkFails() throws {
        try FileManager.default.linkItem(at: resource, to: root.appendingPathComponent("alias"))
        XCTAssertThrowsError(try validate())
    }
    func testFIFOIsRejectedWithoutBlocking() throws {
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path, 0o600), 0)
        XCTAssertThrowsError(try validate())
    }
    func testOwnerMismatchFails() throws {
        XCTAssertThrowsError(try LocalDevelopmentInstallation.validateTree(bundle: root,
            expectedOwner: getuid() == 0 ? 501 : 0, checkAncestors: false))
    }
    func testAncestorsAreChecked() throws {
        // The temporary tree belongs to this user; / and /private do not.
        XCTAssertNotEqual(getuid(), 0)
        XCTAssertThrowsError(try LocalDevelopmentInstallation.validateTree(bundle: root,
            expectedOwner: getuid(), checkAncestors: true))
    }
    func testUnexpectedInstallLocationFails() {
        XCTAssertThrowsError(try LocalDevelopmentInstallation.validate(bundle: root))
    }
    func testSetuidFileFails() throws {
        XCTAssertEqual(chmod(resource.path, 0o4644), 0)
        XCTAssertThrowsError(try validate())
    }
    func testExtendedACLIsRejected() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(String(cString: getpwuid(getuid()).pointee.pw_name)) allow read,readattr,readextattr,readsecurity", resource.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try validate())
    }
    func testExactBuildRequirementCompilesAndCannotUseAnotherHash() throws {
        let hash = Data(repeating: 0x12, count: 20)
        let text = try LocalDevelopmentSigning.requirement(team: "ABCDEFGHIJ", hash: hash)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertTrue(text.contains("cdhash H\"\(String(repeating: "12", count: 20))\""))
        XCTAssertNotEqual(text, try LocalDevelopmentSigning.requirement(team: "ABCDEFGHIJ", hash: Data(repeating: 0x13, count: 20)))
    }
    func testInvalidIdentityInputsFailClosed() {
        XCTAssertThrowsError(try LocalDevelopmentSigning.requirement(team: "\" or true", hash: Data(count: 20)))
        for length in [0, 19, 21, 32] {
            XCTAssertThrowsError(try LocalDevelopmentSigning.requirement(team: "ABCDEFGHIJ", hash: Data(count: length)))
        }
    }
    func testInjectionEntitlementsAndMissingRuntimeFailClosed() throws {
        let runtime = SecCodeSignatureFlags.runtime.rawValue
        try LocalDevelopmentSigning.validateHardening(flags: runtime, entitlements: [:])
        XCTAssertThrowsError(try LocalDevelopmentSigning.validateHardening(flags: 0, entitlements: [:]))
        for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory"] {
            XCTAssertThrowsError(try LocalDevelopmentSigning.validateHardening(flags: runtime, entitlements: [key: true]))
        }
    }
}
