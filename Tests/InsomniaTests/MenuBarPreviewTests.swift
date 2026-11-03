import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

@MainActor
final class MenuBarPreviewTests: XCTestCase {
    func testRenderRealMenuBarComponents() async throws {
        _ = NSApplication.shared
        let h = Harness(); defer { h.home.destroy() }
        let directory = ProcessInfo.processInfo.environment["INSOMNIA_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
            ?? h.home.root.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = h.makeManager()
        let model = MenuBarModel()
        try capture("idle", manager: manager, model: model, directory: directory)
        model.phase = .entering(.start)
        model.slotsPresent = true
        model.visiblePills = 3
        model.input = DurationInput(hours: 8)
        model.focused = .hours
        model.focusVisible = true
        try capture("duration", manager: manager, model: model, directory: directory)
        model.slotsPresent = false
        model.phase = .running
        await manager.start(duration: 3600)
        try capture("timed", manager: manager, model: model, directory: directory)
        await manager.end(reason: .user)
        await manager.startPermanently()
        model.phase = .running
        try capture("permanent", manager: manager, model: model, directory: directory)
        await manager.end(reason: .user)
    }
    private func capture(_ name: String, manager: SessionManager, model: MenuBarModel, directory: URL) throws {
        let root = StatusRootView(model: model, manager: manager,
            onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in }, onStartPermanent: {})
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 100)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
