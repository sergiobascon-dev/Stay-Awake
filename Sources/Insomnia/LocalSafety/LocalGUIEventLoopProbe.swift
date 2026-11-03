import AppKit
import Foundation
import Darwin

/// Actual packaged-process regression check. No settings, power service,
/// app manager, network, saved data or user processes are touched.
enum LocalGUIEventLoopProbe {
    @MainActor
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            FileHandle.standardError.write(Data("FAIL: MainActor tasks cannot run inside the AppKit event loop\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            guard app.isRunning else {
                FileHandle.standardError.write(Data("FAIL: event-loop probe ran before AppKit started\n".utf8))
                exit(1)
            }
            print("PASS: a MainActor task executes inside the real AppKit event loop.")
            exit(0)
        }
        app.run()
        exit(1)
    }
}
