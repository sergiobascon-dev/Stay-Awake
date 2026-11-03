import Foundation
import JavaScriptCore
import XCTest

final class LocalInstallerPreflightTests: XCTestCase {
    private func evaluate(existing: [String], function: String = "freshInstall") throws -> (Bool, String?, String?) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/package-resources/preflight.js"), encoding: .utf8)
        let paths = String(decoding: try JSONSerialization.data(withJSONObject: existing), as: UTF8.self)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var existing = \(paths); var my = {result:{}}; var system = {files:{fileExistsAtPath:function(p){return existing.indexOf(p) !== -1;}}};")
        context.evaluateScript(script)
        let result = try XCTUnwrap(context.evaluateScript("\(function)()"))
        XCTAssertNil(context.exception)
        let type = context.evaluateScript("my.result.type")
        let message = context.evaluateScript("my.result.message")
        return (result.toBool(), type?.isUndefined == false ? type?.toString() : nil,
                message?.isUndefined == false ? message?.toString() : nil)
    }
    func testFreshInstallationIsAllowed() throws {
        let (allowed, type, message) = try evaluate(existing: [])
        XCTAssertTrue(allowed)
        XCTAssertNil(type)
        XCTAssertNil(message)
    }
    func testExistingAppOrRecoveryBlocksReplacementWithFatalMessage() throws {
        for path in ["/Library/Application Support/InsomniaSafeLocal", "/Library/Application Support/InsomniaLocalPower"] {
            let (allowed, type, message) = try evaluate(existing: [path])
            XCTAssertFalse(allowed)
            XCTAssertEqual(type, "Fatal")
            XCTAssertTrue(try XCTUnwrap(message).contains("no se sobrescribirá"))
        }
    }
    func testPreparedUpdateRequiresAnExistingAppAndNoRootRecoveryStore() throws {
        let (allowed, _, _) = try evaluate(existing: ["/Library/Application Support/InsomniaSafeLocal"], function: "preparedUpdate")
        XCTAssertTrue(allowed)
    }
    func testPreparedUpdateCannotSkipAnExistingRootRecoveryStore() throws {
        let (allowed, type, message) = try evaluate(existing: ["/Library/Application Support/InsomniaSafeLocal", "/Library/Application Support/InsomniaLocalPower"], function: "preparedUpdate")
        XCTAssertFalse(allowed)
        XCTAssertEqual(type, "Fatal")
        XCTAssertTrue(try XCTUnwrap(message).contains("recuperación"))
    }
    func testUpdatePackageCannotBeUsedForAFreshInstallation() throws {
        let (allowed, type, _) = try evaluate(existing: [], function: "preparedUpdate")
        XCTAssertFalse(allowed)
        XCTAssertEqual(type, "Fatal")
    }

}
