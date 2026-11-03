import Foundation

/// An active keep-awake session. Timed sessions end at `endsAt`. Permanent
/// sessions have no user deadline, but use independently expiring power leases.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date
    /// Every extension applied, in order, in seconds.
    var extensions: [TimeInterval]
    var isPermanent: Bool

    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = [], isPermanent: Bool = false) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.isPermanent = isPermanent
    }

    private enum CodingKeys: String, CodingKey { case startedAt, endsAt, extensions, isPermanent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        extensions = try c.decode([TimeInterval].self, forKey: .extensions)
        isPermanent = try c.decodeIfPresent(Bool.self, forKey: .isPermanent) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endsAt, forKey: .endsAt)
        try c.encode(extensions, forKey: .extensions)
        if isPermanent { try c.encode(true, forKey: .isPermanent) }
    }

    /// Permanent is a UI lifetime, never an infinite privileged lease.
    /// Each renewal buys at most 60 seconds; without the app it expires.
    func powerLeaseDeadline(at now: Date) -> Date {
        isPermanent ? now.addingTimeInterval(60) : endsAt
    }

    /// Seconds left until `endsAt`, never negative.
    func remaining(at now: Date) -> TimeInterval {
        isPermanent ? .infinity : SessionMath.remaining(until: endsAt, at: now)
    }

    /// True once `now` reaches `endsAt`.
    func isExpired(at now: Date) -> Bool {
        !isPermanent && SessionMath.isExpired(endsAt: endsAt, at: now)
    }

    /// Shape of the menu bar countdown, derived from the session's span so it
    /// survives a relaunch without another persisted field. Because
    /// `remaining` never exceeds this span, the shape always has room for the
    /// value. An extension widens the span and can promote the shape, which
    /// is a one-off change at a user action, never a per-tick one.
    var countdownShape: CountdownShape {
        CountdownShape(initialDuration: endsAt.timeIntervalSince(startedAt))
    }
}
