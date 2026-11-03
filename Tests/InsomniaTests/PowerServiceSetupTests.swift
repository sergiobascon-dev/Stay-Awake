import AppKit
import SwiftUI
import ServiceManagement
import XCTest
@testable import Insomnia

@MainActor
final class PowerServiceSetupTests: XCTestCase {
    func testOpeningSettingsOnlyInspectsAndDoesNotRegister() async {
        var registers = 0
        let setup = PowerServiceSetup(readStatus: { .notRegistered }, validate: {},
            register: { registers += 1 }, probe: { XCTFail("No service to probe") })
        await setup.refresh()
        XCTAssertFalse(setup.busy)
        XCTAssertFalse(setup.ready)
        XCTAssertEqual(registers, 0)
        XCTAssertTrue(setup.message?.contains("Pulsa Configurar") == true)
    }

    func testRegistrationReachesApprovalAndThenVerifiesTheService() async {
        var status = SMAppService.Status.notRegistered
        var probes = 0
        let setup = PowerServiceSetup(readStatus: { status }, validate: {},
            register: { status = .requiresApproval }, probe: { probes += 1 })
        await setup.registerService()
        XCTAssertEqual(setup.status, .requiresApproval)
        XCTAssertFalse(setup.ready)
        XCTAssertTrue(setup.message?.contains("Autoriza Stay Awake") == true)
        status = .enabled
        await setup.refresh()
        XCTAssertTrue(setup.ready)
        XCTAssertEqual(probes, 1)
    }

    func testRegistrationEPERMWithPendingApprovalIsActionable() async {
        let setup = PowerServiceSetup(readStatus: { .requiresApproval }, validate: {},
            register: { throw NSError(domain: SMAppServiceErrorDomain, code: 1) }, probe: {})
        await setup.registerService()
        XCTAssertFalse(setup.ready)
        XCTAssertFalse(setup.busy)
        XCTAssertTrue(setup.message?.contains("Autoriza Stay Awake") == true)
    }

    func testRegistrationFailureDoesNotDisappear() async {
        let setup = PowerServiceSetup(readStatus: { .notRegistered }, validate: {},
            register: { throw LeaseFailure(message: "fixture denied") }, probe: {})
        await setup.registerService()
        XCTAssertFalse(setup.ready)
        XCTAssertFalse(setup.busy)
        XCTAssertTrue(setup.message?.contains("fixture denied") == true)
    }

    func testBadSignaturePreventsRegistration() async {
        var registers = 0
        let setup = PowerServiceSetup(readStatus: { .notRegistered },
            validate: { throw LeaseFailure(message: "fixture signature mismatch") },
            register: { registers += 1 }, probe: {})
        await setup.registerService()
        XCTAssertEqual(registers, 0)
        XCTAssertFalse(setup.ready)
        XCTAssertTrue(setup.message?.contains("signature mismatch") == true)
    }

    func testEnabledStatusAloneCannotClaimReadinessOrKeepStaleReadiness() async {
        var reachable = true
        let setup = PowerServiceSetup(readStatus: { .enabled }, validate: {}, register: {}, probe: {
            if !reachable { throw LeaseFailure(message: "fixture identity mismatch") }
        })
        await setup.refresh()
        XCTAssertTrue(setup.ready)
        reachable = false
        await setup.refresh()
        XCTAssertFalse(setup.ready)
        XCTAssertTrue(setup.message?.contains("identity mismatch") == true)
    }

    func testBusyProbeCannotStartASecondRegistration() async throws {
        var registers = 0
        let setup = PowerServiceSetup(readStatus: { .enabled }, validate: {}, register: { registers += 1 }, probe: {
            try await Task.sleep(for: .milliseconds(150))
        })
        let checking = Task { await setup.refresh() }
        for _ in 0..<100 where !setup.busy { await Task.yield() }
        XCTAssertTrue(setup.busy)
        await setup.registerService()
        XCTAssertEqual(registers, 0)
        await checking.value
        XCTAssertTrue(setup.ready)
        XCTAssertFalse(setup.busy)
    }

    func testRealSettingsRootRunsSetupLifecycleAndDisplaysUpdatedState() async throws {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        var probes = 0
        var registers = 0
        let setup = PowerServiceSetup(readStatus: { .enabled }, validate: {},
            register: { registers += 1 }, probe: { probes += 1 })
        let view = SettingsView(manager: h.makeManager(),
            secrets: KeychainHotspotSecretStore(keychain: FakeKeychainStore()) { "" },
            locationPermission: LocationPermission(),
            loginItem: LoginItem(service: FakeLoginItemService(status: .notRegistered), install: "test", activity: NotificationCenter()),
            releases: ReleaseChecker(), powerSetup: setup)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Stay Awake — isolated UI test"
        window.setContentSize(NSSize(width: 520, height: 720))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentViewController = nil }
        for _ in 0..<100 where !setup.ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(setup.ready, "The settings lifecycle must run outside the extracted Form Section")
        XCTAssertGreaterThan(probes, 0)
        XCTAssertEqual(registers, 0)
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["INSOMNIA_SETUP_PREVIEW"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
