import Foundation
import Security
import ServiceManagement
import Darwin

@objc protocol LocalPowerService {
    /// Fixed vocabulary. No executable, command arguments, paths, baselines,
    /// configuration files or shell fragments are accepted from the caller.
    func request(_ action: String, deadline: Double, reply: @escaping (String) -> Void)
}

enum PowerBrokerPolicy {
    static let service = "local.insomnialocal.power"
    static let daemonPlist = "local.insomnialocal.power.plist"

    static func requirement(forTeam team: String) throws -> String {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw LeaseFailure(message: "Invalid Developer ID team")
        }
        return "anchor apple generic and identifier \"local.insomnialocal.app\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func requirement() throws -> String {
#if INSOMNIA_LOCAL_DEVELOPMENT
        try LocalDevelopmentInstallation.validate(bundle: Bundle.main.bundleURL)
#endif
        return try buildRequirement()
    }

    /// Signature-only inspection for packaging. Never used to authorize RPCs
    /// or registration; those must also pass the protected-installation check.
    static func buildRequirement() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw LeaseFailure(message: "Cannot inspect this executable's signature")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw LeaseFailure(message: "Cannot inspect static signature")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
              identifier == "local.insomnialocal.app" else {
            throw LeaseFailure(message: "Full power mode requires a Developer ID signed Stay Awake build. No sudoers fallback is allowed.")
        }
        let requirement: String
#if INSOMNIA_LOCAL_DEVELOPMENT
        guard let hash = dict[kSecCodeInfoUnique as String] as? Data else {
            throw LeaseFailure(message: "Missing code-directory hash")
        }
        try LocalDevelopmentSigning.validateHardening(
            flags: (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0,
            entitlements: dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:])
        requirement = try LocalDevelopmentSigning.requirement(team: team, hash: hash)
#else
        requirement = try Self.requirement(forTeam: team)
#endif
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled, SecCodeCheckValidity(code, [], compiled) == errSecSuccess,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)), compiled) == errSecSuccess else {
            throw LeaseFailure(message: "Code identity or sealed resources failed validation; no privileged operation is allowed")
        }
        return requirement
    }
}

/// Root-only file, never shared with the app's user-writable journal.
struct RootLeaseStore: LeasePersistence {
    let directory: URL
    let expectedOwner: uid_t
    // expectedOwner is injectable only in-process for filesystem tests. The
    // daemon always uses the default root owner and fixed directory.
    init(directory: URL = URL(fileURLWithPath: "/Library/Application Support/InsomniaLocalPower"), expectedOwner: uid_t = 0) {
        self.directory = directory
        self.expectedOwner = expectedOwner
    }
    private var file: URL { directory.appendingPathComponent("power-lease.json") }

    private func checkDirectory() throws {
        guard geteuid() == expectedOwner else { throw LeaseFailure(message: "Power journal owner mismatch") }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid == expectedOwner, st.st_mode & 0o077 == 0 else {
            throw LeaseFailure(message: "Unsafe root lease directory; refusing power changes")
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LeaseFailure(message: "Cannot open root lease directory") }
        defer { close(fd) }
        try rejectACL(fd)
    }
    private func rejectACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // macOS returns ENOENT for an object with no extended ACL.
            if errno == ENOENT { return }
            throw LeaseFailure(message: "Cannot verify lease permissions: errno \(errno)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 else {
            throw LeaseFailure(message: "Extended ACL on power recovery storage; refusing power changes")
        }
    }
    func load() throws -> PowerLease? {
        try checkDirectory()
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw LeaseFailure(message: "Cannot open root power journal") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == expectedOwner,
              st.st_nlink == 1, st.st_mode & 0o077 == 0, st.st_size <= 65536 else {
            throw LeaseFailure(message: "Unsafe root power journal")
        }
        try rejectACL(fd)
        let data = try handle.readToEnd() ?? Data()
        return try JSONDecoder().decode(PowerLease.self, from: data)
    }
    func removeAfterRecovery() throws {
        guard try load() == nil else { throw LeaseFailure(message: "Power recovery is still pending") }
        guard rmdir(directory.path) == 0 else {
            throw LeaseFailure(message: "Power recovery directory is not empty or cannot be removed")
        }
    }
    func save(_ lease: PowerLease?) throws {
        try checkDirectory()
        if let lease {
            let data = try JSONEncoder().encode(lease)
            let tmp = directory.appendingPathComponent(".lease-\(UUID().uuidString)")
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw LeaseFailure(message: "Cannot create power journal") }
            defer { close(fd); unlink(tmp.path) }
            try rejectACL(fd)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw LeaseFailure(message: "Power journal write failed") }
                    offset += count
                }
            }
            guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0,
                  rename(tmp.path, file.path) == 0 else { throw LeaseFailure(message: "Power journal commit failed") }
        } else if unlink(file.path) != 0 && errno != ENOENT {
            throw LeaseFailure(message: "Cannot clear power recovery journal")
        }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw LeaseFailure(message: "Cannot sync root journal directory") }
        defer { close(dir) }
        guard fsync(dir) == 0 else { throw LeaseFailure(message: "Cannot sync root journal directory") }
    }
}

/// The only implementation that executes pmset mutations. It is constructed
/// exclusively in the privileged daemon. Absolute executable and fixed argv.
final class RootPowerSystem: LeasePowerSystem {
    private var unfinished: Process?
    private func run(_ args: [String]) throws -> String {
        if let unfinished, unfinished.isRunning {
            throw LeaseFailure(message: "Previous pmset still running; recovery remains pending")
        }
        unfinished = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        // Capture to an exclusively created regular file. Reading a pipe
        // after the parent exits can hang forever if a descendant inherited
        // stdout, which would also stop the independent recovery timer.
        let outputURL = URL(fileURLWithPath: "/private/tmp/insomnia-local-pmset-\(UUID().uuidString)")
        let fd = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LeaseFailure(message: "Cannot create private pmset output") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { close(fd); unlink(outputURL.path) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let end = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            unfinished = process
            throw LeaseFailure(message: "pmset timed out; recovery retained, no concurrent mutations allowed")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= 65536 else {
            throw LeaseFailure(message: "Unexpectedly large pmset output")
        }
        try output.seek(toOffset: 0)
        let data = try output.read(upToCount: 65536) ?? Data()
        guard process.terminationStatus == 0 else { throw LeaseFailure(message: "pmset failed: \(process.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
    }
    func readSleep() throws -> Bool {
        guard let value = PmsetSleepGuard.readEffectiveSleepDisabled(try run(["-g"])) else {
            throw LeaseFailure(message: "Cannot read original sleep setting")
        }
        return value
    }
    func readLowPower() throws -> Bool {
        guard let value = PmsetSleepGuard.parseLowPowerMode(try run(["-g", "custom"])) else {
            throw LeaseFailure(message: "Cannot read battery Low Power Mode; full mode unavailable")
        }
        return value
    }
    func writeSleep(_ value: Bool) throws { _ = try run(["-a", "disablesleep", value ? "1" : "0"]) }
    func writeLowPower(_ value: Bool) throws { _ = try run(["-b", "lowpowermode", value ? "1" : "0"]) }
}

private final class PowerEndpoint: NSObject, LocalPowerService, @unchecked Sendable {
    let owner: UInt32
    let broker: PowerBrokerDaemon
    init(owner: UInt32, broker: PowerBrokerDaemon) { self.owner = owner; self.broker = broker }
    func request(_ action: String, deadline: Double, reply: @escaping (String) -> Void) {
        // NSXPC's reply block is passed between its queue and our serial queue.
        let response = BrokerReply(reply)
        broker.queue.async { [self] in
            do {
                switch action {
                case "begin":
                    guard !broker.retiring else { throw LeaseFailure(message: "Power service is being uninstalled") }
                    let snapshot = PowerMonitor.readBattery()
                    guard ProcessInfo.processInfo.thermalState != .critical,
                          snapshot.charging || snapshot.battery == .none || snapshot.battery.percent.map({ $0 > 10 }) == true else {
                        throw LeaseFailure(message: "Battery or temperature prevents starting a session")
                    }
                    try broker.engine.renew(owner: owner, until: Date(timeIntervalSince1970: deadline), now: Date())
                case "renew": try broker.engine.renew(owner: owner, until: Date(timeIntervalSince1970: deadline), now: Date(), allowNew: false)
                case "low-on": try broker.engine.lowPower(owner: owner, enabled: true)
                case "low-off":
                    let snapshot = PowerMonitor.readBattery()
                    let floorNeedsLow = ProcessInfo.processInfo.thermalState == .serious
                        || (!snapshot.charging && snapshot.battery.percent.map({ $0 <= 40 }) == true)
                    try broker.engine.releaseLowPowerRequest(owner: owner, safetyRequiresLow: floorNeedsLow)
                case "release": try broker.engine.release(owner: owner)
                case "retire":
                    try broker.engine.release(owner: owner)
                    try RootLeaseStore().removeAfterRecovery()
                    broker.retiring = true
                case "status": break
                case "probe":
                    guard let lease = broker.engine.lease, lease.owner == owner, !broker.engine.recovering,
                          Date() < lease.endsAt,
                          Date().timeIntervalSince(lease.heartbeatAt) < PowerLeaseEngine.heartbeatLimit else {
                        throw LeaseFailure(message: "No live power lease")
                    }
                default: throw LeaseFailure(message: "Unknown power operation")
                }
                response.send("")
            } catch { response.send(error.localizedDescription) }
        }
    }
}
private final class BrokerReply: @unchecked Sendable {
    let send: (String) -> Void
    init(_ send: @escaping (String) -> Void) { self.send = send }
}

final class PowerBrokerDaemon: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.insomnialocal.power.serial")
    let engine: PowerLeaseEngine
    let requirement: String
    private var timer: DispatchSourceTimer?
    fileprivate var retiring = false
    init(engine: PowerLeaseEngine, requirement: String) { self.engine = engine; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        // Kernel-enforced per-message requirement: no PID lookup race.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: LocalPowerService.self)
        connection.exportedObject = PowerEndpoint(owner: connection.effectiveUserIdentifier, broker: self)
        connection.resume()
        return true
    }
    func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(5))
        timer.setEventHandler { [self] in
            let snapshot = PowerMonitor.readBattery()
            do {
                try engine.tick(now: Date(), battery: snapshot.battery.percent,
                    hasBattery: snapshot.battery != .none, onAC: snapshot.charging,
                    thermal: ProcessInfo.processInfo.thermalState)
            } catch {
                // Unified log, never the user's writable log path from root.
                NSLog("Stay Awake power recovery pending: %@", error.localizedDescription)
            }
        }
        self.timer = timer
        timer.resume()
    }
    static func run() -> Never {
        do {
            guard geteuid() == 0 else { throw LeaseFailure(message: "Not a root launchd daemon") }
            let engine = try PowerLeaseEngine(system: RootPowerSystem(), persistence: RootLeaseStore())
            let requirement: String
            do { requirement = try PowerBrokerPolicy.requirement() }
            catch {
                // An expired development certificate or damaged installation
                // must not strand an existing lease. Restore only; expose no
                // endpoint and accept no new requests in this state.
                NSLog("Stay Awake authentication failed; recovery only: %@", error.localizedDescription)
                let daemon = PowerBrokerDaemon(engine: engine, requirement: "false")
                daemon.startMonitoring()
                withExtendedLifetime(daemon) { RunLoop.current.run() }
                exit(0)
            }
            let daemon = PowerBrokerDaemon(engine: engine, requirement: requirement)
            let listener = NSXPCListener(machServiceName: PowerBrokerPolicy.service)
            listener.delegate = daemon
            daemon.startMonitoring()
            listener.resume()
            withExtendedLifetime((daemon, listener)) { RunLoop.current.run() }
            exit(0)
        } catch {
            fputs("Power service refused: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
