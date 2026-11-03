import Foundation

/// Root-owned recovery state. The privileged service never trusts a caller's
/// claimed baseline or a path supplied over XPC.
struct PowerLease: Codable, Equatable, Sendable {
    var owner: UInt32
    var endsAt: Date
    var heartbeatAt: Date
    var originalSleepDisabled: Bool
    var originalLowPower: Bool
    var requestedLowPower: Bool
    var restoreSleep: Bool
    var restoreLowPower: Bool
}

protocol LeasePowerSystem {
    func readSleep() throws -> Bool
    func readLowPower() throws -> Bool
    func writeSleep(_ value: Bool) throws
    func writeLowPower(_ value: Bool) throws
}

protocol LeasePersistence {
    func load() throws -> PowerLease?
    func save(_ lease: PowerLease?) throws
}

struct LeaseFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Synchronous by design: called only on the broker's serial queue, so there
/// can never be two pmset mutations or a restore racing a new session.
final class PowerLeaseEngine {
    static let heartbeatLimit: TimeInterval = 90
    static let maximumDuration: TimeInterval = 30 * 24 * 3600
    let system: any LeasePowerSystem
    let persistence: any LeasePersistence
    private(set) var lease: PowerLease?
    private(set) var recovering = false
    private var consecutiveBatteryMisses = 0

    init(system: any LeasePowerSystem, persistence: any LeasePersistence) throws {
        self.system = system
        self.persistence = persistence
        lease = try persistence.load()
        // A restarted daemon never silently resurrects a keep-awake session.
        recovering = lease != nil
    }

    func renew(owner: UInt32, until: Date, now: Date, allowNew: Bool = true) throws {
        guard until.timeIntervalSince(now) > 0,
              until.timeIntervalSince(now) <= Self.maximumDuration,
              until.timeIntervalSince1970.isFinite else {
            throw LeaseFailure(message: "Invalid session deadline")
        }
        guard !recovering else { throw LeaseFailure(message: "Power recovery is still pending") }
        if var current = lease {
            guard current.owner == owner else { throw LeaseFailure(message: "Another user owns the session") }
            // An overdue heartbeat cannot revive a lease before its timer runs.
            guard now < current.endsAt, now.timeIntervalSince(current.heartbeatAt) < Self.heartbeatLimit,
                  now.timeIntervalSince(current.heartbeatAt) >= -5 else {
                recovering = true
                try restore()
                throw LeaseFailure(message: "The previous power lease expired; start a new session")
            }
            current.endsAt = until
            current.heartbeatAt = now
            try persistence.save(current)
            lease = current
            return
        }
        guard allowNew else { throw LeaseFailure(message: "Power lease has ended; renew cannot start another") }
        let sleep = try system.readSleep()
        let low = try system.readLowPower()
        guard !sleep else {
            throw LeaseFailure(message: "Sleep is already disabled by another tool; nothing changed")
        }
        let initial = PowerLease(owner: owner, endsAt: until, heartbeatAt: now,
            originalSleepDisabled: sleep, originalLowPower: low,
            requestedLowPower: false, restoreSleep: true, restoreLowPower: false)
        // Intent is durable BEFORE the command; a crash at any following byte
        // has enough information to restore the original state.
        try persistence.save(initial)
        lease = initial
        do {
            try system.writeSleep(true)
            guard try system.readSleep() else { throw LeaseFailure(message: "Sleep prevention did not take effect") }
        } catch {
            recovering = true
            // Keep the original error; a failed recovery remains journaled.
            try? restore()
            throw error
        }
    }

    func lowPower(owner: UInt32, enabled: Bool) throws {
        guard var current = lease else {
            // Releasing an already restored Low Power claim is idempotent.
            if !enabled { return }
            throw LeaseFailure(message: "No active power lease")
        }
        guard current.owner == owner, !recovering else { throw LeaseFailure(message: "Lease unavailable for this user") }
        // An off request must not take ownership of a preference changed
        // independently when this lease never wrote Low Power Mode.
        if !enabled && !current.restoreLowPower {
            if current.requestedLowPower {
                current.requestedLowPower = false
                try persistence.save(current)
                lease = current
            }
            return
        }
        let observed = try system.readLowPower()
        let desired = current.originalLowPower || enabled
        current.requestedLowPower = enabled
        if observed != desired { current.restoreLowPower = true }
        if current != lease {
            try persistence.save(current)
            lease = current
        }
        if observed != desired {
            try system.writeLowPower(desired)
            guard try system.readLowPower() == desired else {
                throw LeaseFailure(message: "Low Power Mode read-back failed")
            }
        }
        if !enabled && current.restoreLowPower {
            // This undo is complete now. Keeping ownership until session end
            // could overwrite a later, independent user preference change.
            current.restoreLowPower = false
            try persistence.save(current)
            lease = current
        }
    }

    func releaseLowPowerRequest(owner: UInt32, safetyRequiresLow: Bool) throws {
        if safetyRequiresLow, lease != nil {
            try lowPower(owner: owner, enabled: true)
            throw LeaseFailure(message: "Independent battery or thermal protection still requires Low Power Mode")
        }
        try lowPower(owner: owner, enabled: false)
    }

    func release(owner: UInt32) throws {
        guard let current = lease else { return }
        guard current.owner == owner else { throw LeaseFailure(message: "Another user owns the session") }
        recovering = true
        try restore()
    }

    /// Independent of the UI and its config: protections cannot be disabled
    /// through XPC. Missing battery readings on a laptop end the lease.
    func tick(now: Date, battery: Int?, hasBattery: Bool, onAC: Bool,
              thermal: ProcessInfo.ThermalState) throws {
        guard let current = lease else { return }
        if hasBattery && !onAC && battery == nil { consecutiveBatteryMisses += 1 }
        else { consecutiveBatteryMisses = 0 }
        if recovering || now >= current.endsAt
            || now.timeIntervalSince(current.heartbeatAt) >= Self.heartbeatLimit
            || now.timeIntervalSince(current.heartbeatAt) < -5
            || thermal == .critical
            || (hasBattery && !onAC && (battery.map { $0 <= 10 } == true || consecutiveBatteryMisses >= 2)) {
            recovering = true
            try restore()
            return
        }
        // Detect competing power tools that silently re-enable sleep. Do not
        // keep advertising an awake session or fight the other tool forever.
        let sleepIsDisabled: Bool
        do { sleepIsDisabled = try system.readSleep() }
        catch {
            recovering = true
            try? restore()
            throw error
        }
        if !sleepIsDisabled {
            recovering = true
            try restore()
            return
        }
        if thermal == .serious || (hasBattery && !onAC && battery.map({ $0 <= 40 }) == true) {
            try lowPower(owner: current.owner, enabled: true)
        }
    }

    /// Each confirmed undo is committed independently. A failed command or
    /// failed read-back keeps its entry; deleting the journal is the last step.
    func restore() throws {
        guard var current = lease else { recovering = false; return }
        var first: Error?
        if current.restoreSleep {
            do {
                try system.writeSleep(current.originalSleepDisabled)
                guard try system.readSleep() == current.originalSleepDisabled else { throw LeaseFailure(message: "Sleep restore read-back failed") }
                current.restoreSleep = false
                try persistence.save(current)
                lease = current
            } catch { current = lease!; first = error }
        }
        if current.restoreLowPower {
            do {
                try system.writeLowPower(current.originalLowPower)
                guard try system.readLowPower() == current.originalLowPower else { throw LeaseFailure(message: "Low Power restore read-back failed") }
                current.restoreLowPower = false
                try persistence.save(current)
                lease = current
            } catch { current = lease!; if first == nil { first = error } }
        }
        if let first { throw first }
        try persistence.save(nil)
        lease = nil
        recovering = false
        consecutiveBatteryMisses = 0
    }
}
