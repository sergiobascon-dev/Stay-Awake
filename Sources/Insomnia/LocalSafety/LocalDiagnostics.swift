import Foundation
import IOKit.pwr_mgt
import Darwin

/// Explicitly invoked diagnostics. Never touches network, saved preferences,
/// services, login items, sudoers or unrelated processes.
enum LocalDiagnostics {
    static func run(_ args: [String]) async -> Int32? {
        guard args == ["--local-doctor"] || args == ["--local-self-test"] else { return nil }
        var report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "mode": args[0],
            "persistentSettingsWritesPerformed": false,
            "privilegedServiceInstalledByThisCommand": false
        ]
        do {
            let runner = CancellableCommand()
            let sleep = try await runner.run("/usr/bin/pmset", ["-g"], timeout: 5)
            let custom = try await runner.run("/usr/bin/pmset", ["-g", "custom"], timeout: 5)
            guard sleep.succeeded, custom.succeeded,
                  let disabled = PmsetSleepGuard.readEffectiveSleepDisabled(sleep.stdout) else {
                throw LeaseFailure(message: "Cannot read energy settings")
            }
            report["sleepDisabledBefore"] = disabled
            report["batteryLowPowerBefore"] = PmsetSleepGuard.parseLowPowerMode(custom.stdout) as Any?
            do { _ = try PowerBrokerPolicy.requirement(); report["developerSignatureAvailable"] = true }
            catch { report["developerSignatureAvailable"] = false; report["fullModeBlockedReason"] = error.localizedDescription }
            if args == ["--local-self-test"] {
                try await testOwnedChild()
                report["ownedChildPauseResume"] = "passed"
                try await testTemporaryAssertion()
                report["temporaryAwakeAssertionCreatedAndReleased"] = "passed"
                let after = try await runner.run("/usr/bin/pmset", ["-g"], timeout: 5)
                let customAfter = try await runner.run("/usr/bin/pmset", ["-g", "custom"], timeout: 5)
                guard after.succeeded, customAfter.succeeded,
                      PmsetSleepGuard.readEffectiveSleepDisabled(after.stdout) == disabled,
                      PmsetSleepGuard.parseLowPowerMode(customAfter.stdout) == PmsetSleepGuard.parseLowPowerMode(custom.stdout) else {
                    throw LeaseFailure(message: "Energy settings changed during the smoke test; inspect before proceeding")
                }
                report["energyBaselineUnchanged"] = true
            }
            report["result"] = "passed"
            emit(report)
            return 0
        } catch {
            report["result"] = "failed"
            report["error"] = error.localizedDescription
            emit(report)
            return 1
        }
    }
    private static func emit(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
    private static func testOwnedChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let pid = child.processIdentifier
        // Always resume before termination, including a failure halfway through.
        defer { kill(pid, SIGCONT); child.terminate(); child.waitUntilExit() }
        guard case let .present(state) = SignalProcessControl.kernelState(pid: pid), state.ppid == getpid() else {
            throw LeaseFailure(message: "Cannot verify the disposable child identity")
        }
        let control = SignalProcessControl()
        let entry = FrozenProcess(pid: pid, identity: state.identity)
        let stopped = control.suspend([entry], expectedParents: [pid: getpid()])
        guard stopped.suspended == [pid] else { throw LeaseFailure(message: "Disposable child could not be paused") }
        var observed = false
        for _ in 0..<100 {
            if case let .present(current) = SignalProcessControl.kernelState(pid: pid), current.stopped { observed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard observed else { throw LeaseFailure(message: "Kernel did not confirm stopped state") }
        let resumed = control.resume([entry])
        guard resumed.resumed == [pid] else { throw LeaseFailure(message: "Disposable child could not be resumed") }
        for _ in 0..<100 {
            if case let .present(current) = SignalProcessControl.kernelState(pid: pid), !current.stopped { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LeaseFailure(message: "Kernel did not confirm resumed state")
    }
    private static func testTemporaryAssertion() async throws {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Stay Awake supervised smoke test" as CFString, &id)
        guard result == kIOReturnSuccess else { throw LeaseFailure(message: "Cannot create temporary keep-awake assertion: \(result)") }
        var released = false
        defer { if !released { IOPMAssertionRelease(id) } }
        guard IOPMAssertionCopyProperties(id) != nil else { throw LeaseFailure(message: "Assertion was not observable") }
        try await Task.sleep(for: .seconds(2))
        guard IOPMAssertionRelease(id) == kIOReturnSuccess else { throw LeaseFailure(message: "Assertion release failed") }
        released = true
        guard IOPMAssertionCopyProperties(id) == nil else { throw LeaseFailure(message: "Assertion remained after release") }
    }
}
