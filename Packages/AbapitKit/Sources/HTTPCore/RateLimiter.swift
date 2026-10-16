import Foundation

/// One credential's request budget (plan §3.3): a token bucket per lane, reads and writes apart. Apple
/// documents 429 but no numbers; third-party reports say about 20 GETs a minute and 10 POSTs an hour
/// (unverified). So it starts there, halves on a 429, recovers by 10% after each 20 successes, and the
/// app stores the learned read rate in the org's profile.
public actor RateLimiter {
    public enum Lane: Sendable { case read, write }

    public static let defaultReadsPerMinute = 20.0
    public static let readBurst = 10.0
    public static let defaultWritesPerHour = 10.0
    public static let writeBurst = 3.0
    /// The read rate never goes below this or above `ceiling`, whatever it learns.
    public static let floor = 2.0, ceiling = 600.0

    private struct Bucket {
        var perSecond: Double
        let burst: Double
        let minimum: Double
        let maximum: Double
        var tokens: Double
        var stamp: ContinuousClock.Instant
        var successes = 0
    }

    private var buckets: [Lane: Bucket]
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(readsPerMinute: Double? = nil,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let reads = min(max(readsPerMinute ?? Self.defaultReadsPerMinute, Self.floor), Self.ceiling)
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

    /// A 429: the rate halves (not below the floor) and the bucket empties.
    public func throttled(_ lane: Lane) {
        refill(lane)
        buckets[lane]!.perSecond = max(buckets[lane]!.perSecond / 2, buckets[lane]!.minimum)
        buckets[lane]!.tokens = 0
        buckets[lane]!.successes = 0
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
        let elapsed = current - buckets[lane]!.stamp
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        buckets[lane]!.tokens = min(buckets[lane]!.burst, buckets[lane]!.tokens + seconds * buckets[lane]!.perSecond)
        buckets[lane]!.stamp = current
    }
}
