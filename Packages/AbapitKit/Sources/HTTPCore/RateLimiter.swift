import Foundation

/// One credential's request budget (plan §3.3): a token bucket per lane, reads and writes apart. Apple
/// documents 429 but no numbers; third-party reports say about 20 GETs a minute and 10 POSTs an hour
/// (unverified). So it starts there, halves once per throttle event (a 429, and those inside its hold), recovers by 10%
/// after each 20 successes, and the app stores the learned read rate in the org's profile.
public actor RateLimiter {
    public enum Lane: Sendable { case read, write }

    public static let defaultReadsPerMinute = 20.0
    public static let readBurst = 10.0
    public static let defaultWritesPerHour = 10.0
    public static let writeBurst = 3.0
    /// The read rate never goes below this or above `ceiling`, whatever it learns.
    public static let floor = 2.0, ceiling = 600.0
    /// The longest a 429 holds a lane, whoever asks: `HTTPClient` caps `Retry-After` at the same minute.
    public static let longestHold: Duration = .seconds(60)

    private struct Bucket {
        var perSecond: Double
        let burst: Double
        let minimum: Double
        let maximum: Double
        var tokens: Double
        var stamp: ContinuousClock.Instant
        var successes = 0
        /// Until when the last 429 holds the lane: one throttle event. A 429 before then (another read in flight refused,
        /// a token exchange) extends the hold, never shortens it, and doesn't halve the rate again.
        var heldUntil: ContinuousClock.Instant?
    }

    private var buckets: [Lane: Bucket]
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(readsPerMinute: Double? = nil,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let asked = readsPerMinute.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultReadsPerMinute
        let reads = min(max(asked, Self.floor), Self.ceiling)
        let start = now()
        buckets = [
            .read: Bucket(perSecond: reads / 60, burst: Self.readBurst, minimum: Self.floor / 60, maximum: Self.ceiling / 60,
                          tokens: Self.readBurst, stamp: start),
            .write: Bucket(perSecond: Self.defaultWritesPerHour / 3600, burst: Self.writeBurst, minimum: 1.0 / 3600,
                           maximum: 60.0 / 3600, tokens: Self.writeBurst, stamp: start),
        ]
        self.now = now
        self.sleep = sleep
    }

    /// What the read lane has learned, per minute: the app saves it in the org's profile.
    public var readsPerMinute: Double { buckets[.read]!.perSecond * 60 }

    /// Waits for a token in `lane`. Cancellable.
    public func acquire(_ lane: Lane) async throws {
        while true {
            refill(lane)
            let bucket = buckets[lane]!
            if bucket.tokens >= 1 {
                buckets[lane]!.tokens -= 1
                return
            }
            try await sleep(.seconds((1 - bucket.tokens) / bucket.perSecond))
        }
    }

    /// A 429: one throttle event halves the rate (not below the floor) and holds the lane. With `retryAfter` (the server's
    /// `Retry-After`, at most `longestHold`), no token is given until it has passed, so every request waiting on the lane
    /// honours it, not only the one refused: a sweep has several reads in flight (plan §3.6). Without one, the hold is one
    /// token's time at the new rate. A 429 inside a hold is the same event: the reads in flight were sent before the first
    /// answer, so four refused at once halve the rate once, not four times; it extends the hold to its own `retryAfter` if
    /// that ends later, and never shortens it (a token exchange's 429, which has none, leaves it as it is).
    public func throttled(_ lane: Lane, retryAfter: Duration? = nil) {
        refill(lane)
        var bucket = buckets[lane]!
        let current = bucket.stamp
        let wait = Self.seconds(min(max(retryAfter ?? .zero, .zero), Self.longestHold))
        if let held = bucket.heldUntil, held > current {
            let until = max(held, current.advanced(by: .seconds(wait)))
            bucket.heldUntil = until
            bucket.tokens = min(bucket.tokens, 1 - Self.seconds(until - current) * bucket.perSecond)
        } else {
            bucket.perSecond = max(bucket.perSecond / 2, bucket.minimum)
            // The next token comes after `retryAfter` or one token's time at the new rate, whichever is later.
            bucket.tokens = min(0, 1 - wait * bucket.perSecond)
            bucket.heldUntil = current.advanced(by: .seconds((1 - bucket.tokens) / bucket.perSecond))
        }
        bucket.successes = 0
        buckets[lane] = bucket
    }

    /// A success: every 20 in a row raise the rate by 10%, up to the ceiling.
    public func succeeded(_ lane: Lane) {
        buckets[lane]!.successes += 1
        if buckets[lane]!.successes >= 20 {
            buckets[lane]!.successes = 0
            buckets[lane]!.perSecond = min(buckets[lane]!.perSecond * 1.1, buckets[lane]!.maximum)
        }
    }

    private func refill(_ lane: Lane) {
        let current = now()
        let seconds = Self.seconds(current - buckets[lane]!.stamp)
        buckets[lane]!.tokens = min(buckets[lane]!.burst, buckets[lane]!.tokens + seconds * buckets[lane]!.perSecond)
        buckets[lane]!.stamp = current
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
