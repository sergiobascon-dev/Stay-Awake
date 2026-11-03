import Foundation
import AppKit
import ServiceManagement

private final class PowerReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    var connection: NSXPCConnection?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error? = nil) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        connection?.invalidate()
    }
}

enum PowerBrokerRPC {
    static func send(_ action: String, until: Date = Date()) async throws {
        let requirement = try PowerBrokerPolicy.requirement()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = PowerReplyGate(continuation)
            let connection = NSXPCConnection(machServiceName: PowerBrokerPolicy.service, options: .privileged)
            gate.connection = connection
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: LocalPowerService.self)
            connection.invalidationHandler = { gate.finish(LeaseFailure(message: "Power service unavailable; install and approve the signed service first")) }
            connection.interruptionHandler = { gate.finish(LeaseFailure(message: "Power service interrupted; its recovery journal is retained")) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { gate.finish($0) } as? LocalPowerService
            guard let proxy else { gate.finish(LeaseFailure(message: "Cannot connect to power service")); return }
            proxy.request(action, deadline: until.timeIntervalSince1970) { error in
                gate.finish(error.isEmpty ? nil : LeaseFailure(message: error))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                gate.finish(LeaseFailure(message: "Power service timed out; recovery remains pending"))
            }
        }
    }
}

actor PowerLeaseClient {
    static let shared = PowerLeaseClient()
    private var heartbeat: Task<Void, Never>?
    private var generation = 0
    private var expectedEnd: Date?
    static let failureNotification = Notification.Name("InsomniaLocalPowerLeaseEnded")
    private let send: @Sendable (String, Date) async throws -> Void
    private let renewalInterval: Duration
    private let onFailure: @Sendable () -> Void
    private let checkResponsiveness: @Sendable () async -> Void
    private let clock: @Sendable () -> Date

    init(
        renewalInterval: Duration = .seconds(15),
        send: @escaping @Sendable (String, Date) async throws -> Void = { try await PowerBrokerRPC.send($0, until: $1) },
        onFailure: @escaping @Sendable () -> Void = { NotificationCenter.default.post(name: PowerLeaseClient.failureNotification, object: nil) },
        checkResponsiveness: @escaping @Sendable () async -> Void = { await MainActor.run {} },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.renewalInterval = renewalInterval
        self.send = send
        self.onFailure = onFailure
        self.checkResponsiveness = checkResponsiveness
        self.clock = clock
    }

    func begin(paths: Paths) async throws {
        let session = try Store(paths: paths).loadSession()
        guard let session else { throw LeaseFailure(message: "No journaled session deadline") }
        try await send("begin", session.powerLeaseDeadline(at: clock()))
        expectedEnd = session.isPermanent ? nil : session.endsAt
        generation += 1
        let current = generation
        heartbeat?.cancel()
        let interval = renewalInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.renew(paths: paths, generation: current)
            }
        }
    }
    private func renew(paths: Paths, generation: Int) async {
        guard self.generation == generation else { return }
        do {
            // A live background actor does not prove the interface is alive.
            // If the main actor is stuck, stop buying more root lease time.
            await checkResponsiveness()
            guard self.generation == generation, !Task.isCancelled else { return }
            guard let session = try Store(paths: paths).loadSession() else {
                if let expectedEnd, clock() >= expectedEnd {
                    // The independent supervisor can finish before the GUI
                    // timer gets its next turn. Normal expiry is not failure.
                    Log.info("power heartbeat stopped after expected session expiry")
                    cancelRenewal()
                    return
                }
                throw LeaseFailure(message: "Session was ended by the recovery supervisor")
            }
            expectedEnd = session.isPermanent ? nil : session.endsAt
            try await send("renew", session.powerLeaseDeadline(at: clock()))
        } catch {
            guard self.generation == generation else { return }
            Log.error("power heartbeat failed: \(error.localizedDescription)")
            cancelRenewal()
            onFailure()
        }
    }
    func cancelRenewal() {
        generation += 1
        heartbeat?.cancel()
        heartbeat = nil
        expectedEnd = nil
    }
    func end() async throws {
        cancelRenewal()
        try await send("release", clock())
    }
}

struct BrokerSleepGuard: SleepGuarding {
    let paths: Paths
    private var reader: PmsetSleepGuard { PmsetSleepGuard() }
    func cancelRenewal() async { await PowerLeaseClient.shared.cancelRenewal() }
    func setSleepDisabled(_ disabled: Bool) async throws {
        if disabled { try await PowerLeaseClient.shared.begin(paths: paths) }
        else { try await PowerLeaseClient.shared.end() }
    }
    func isSleepDisabled() async throws -> Bool { try await reader.isSleepDisabled() }
    func setLowPowerMode(_ on: Bool) async throws { try await PowerBrokerRPC.send(on ? "low-on" : "low-off") }
    func isLowPowerModeOn() async throws -> Bool { try await reader.isLowPowerModeOn() }
}

/// Explicit command-line operations, never registered automatically at launch.
enum LocalPowerCommand {
    @MainActor
    private static func recoveryPoll() async -> Int32 {
        do {
            _ = try PowerBrokerPolicy.requirement()
            let paths = Paths.fromEnvironment()
            let store = Store(paths: paths)
            guard try store.loadSession() != nil || (store.loadState() ?? .clean).isDirty else { return 0 }
            let manager = SessionManager.live(paths: paths)
            return await manager.recoverLocalSessionIfNeeded() ? 0 : 1
        } catch {
            print("Recovery pending: \(error.localizedDescription)")
            return 1
        }
    }
    @MainActor
    private static func prepareUninstall() async throws {
        _ = try PowerBrokerPolicy.requirement()
        guard ProcessInfo.processInfo.environment[Paths.environmentKey] == nil else {
            throw LeaseFailure(message: "Uninstall refuses a relocated application home")
        }
        let ownBundle = Bundle.main.bundleURL.standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == ownBundle
        }
        for app in running {
            guard app.terminate() else { throw LeaseFailure(message: "Close Stay Awake before uninstalling") }
        }
        for _ in 0..<150 where running.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard running.allSatisfy(\.isTerminated) else { throw LeaseFailure(message: "The app is still recovering or refused to quit; nothing removed") }
        // Restore root-owned settings before attempting user-session recovery.
        let powerService = SMAppService.daemon(plistName: PowerBrokerPolicy.daemonPlist)
        let powerWasEnabled = powerService.status == .enabled
#if INSOMNIA_LOCAL_DEVELOPMENT
        if powerWasEnabled { try await PowerBrokerRPC.send("release") }
        else {
            // An installation whose setup was cancelled can be removed only
            // if user recovery is already clean. The administrator removal
            // step must independently refuse ANY remaining root journal.
            let store = Store(paths: .standard)
            let userState = try store.loadState() ?? .clean
            guard try store.loadSession() == nil, !userState.isDirty else {
                throw LeaseFailure(message: "Enable the power service to finish recovery before removing the app")
            }
        }
#else
        try await PowerBrokerRPC.send("release")
#endif
        let manager = SessionManager.live(paths: .standard)
        guard await manager.recoverLocalSessionIfNeeded(), !manager.state.isDirty else {
            throw LeaseFailure(message: "User-session recovery is still pending; reconnect saved audio outputs and restore before uninstalling")
        }
        let service = SMAppService.mainApp
        if service.status != .notRegistered { try await service.unregister() }
        let domain = "gui/\(getuid())/\(Paths.backstopLabel)"
        let runner = CancellableCommand()
        _ = try await runner.run("/bin/launchctl", ["bootout", domain], timeout: 15)
        let check = try await runner.run("/bin/launchctl", ["print", domain], timeout: 15)
        guard LocalServiceRemoval.confirmedAbsent(check, label: Paths.backstopLabel) else {
            throw LeaseFailure(message: "Recovery agent removal could not be confirmed; nothing removed")
        }
        // Retiring prevents another client from acquiring a lease between
        // this final restore and unregistering the daemon.
        if powerWasEnabled { try await PowerBrokerRPC.send("retire") }
        if powerService.status != .notRegistered { try await powerService.unregister() }
    }
    static func run(_ args: [String]) async -> Int32? {
        guard let command = args.first, command.hasPrefix("--local-") else { return nil }
        do {
            switch args {
            case ["--local-xpc-self-test"]:
                try await LocalXPCIdentityProbe.run()
            case ["--local-verify-build"]:
                print(try PowerBrokerPolicy.buildRequirement())
            case ["--local-verify-signature"]:
                print(try PowerBrokerPolicy.requirement())
            case ["--local-prepare-uninstall"]:
                try await prepareUninstall()
#if INSOMNIA_LOCAL_DEVELOPMENT
                print("User recovery complete; services unregistered. Administrator removal must still verify that no root journal remains.")
#else
                print("Energy and user-session recovery complete; services unloaded. Application files may now be removed.")
#endif
            case ["--local-register-power"]:
                _ = try PowerBrokerPolicy.requirement()
                try SMAppService.daemon(plistName: PowerBrokerPolicy.daemonPlist).register()
                print("Power service registered. Approve it in System Settings > General > Login Items & Extensions if requested.")
            case ["--local-unregister-power"]:
                try await PowerBrokerRPC.send("release")
                try await SMAppService.daemon(plistName: PowerBrokerPolicy.daemonPlist).unregister()
                print("Power baseline restored and service unregistered.")
            case ["--local-release-power"]:
                try await PowerLeaseClient.shared.end()
                print("Power baseline restored.")
            case ["--local-low-power-off"]:
                try await PowerBrokerRPC.send("low-off")
                print("Low Power claim released.")
            case ["--local-recovery-poll"]:
                return await recoveryPoll()
            case ["--local-power-status"]:
                try await PowerBrokerRPC.send("status")
                print("Signed power service reachable.")
            default: throw LeaseFailure(message: "Unknown local command")
            }
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }
}

/// A failed query can mean permission denied or I/O failure, not absence.
enum LocalServiceRemoval {
    static func confirmedAbsent(_ result: ShellResult, label: String) -> Bool {
        !result.succeeded && result.stderr.contains("Could not find service \"\(label)\"")
    }
}
