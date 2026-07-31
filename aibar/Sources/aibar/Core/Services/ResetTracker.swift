import Foundation

/// Counts how many times a quota window (session/weekly, per provider) has
/// actually rolled over, purely from what this app has observed locally.
///
/// There's no reset history to read: the CLI's local session logs only ever
/// carry the *current* deadline for a limit (see `limitsByKind` in
/// `UsageAggregation`), never a log of past resets. So this can't be
/// backfilled — the count only starts accumulating from whenever this app
/// first sees a given provider+kind, persisted in `UserDefaults` so it
/// survives restarts instead of resetting itself back to zero every launch.
enum ResetTracker {
    private static func lastDeadlineKey(provider: String, kind: String) -> String {
        "resetTracker.lastDeadline.\(provider).\(kind)"
    }
    private static func countKey(provider: String, kind: String) -> String {
        "resetTracker.count.\(provider).\(kind)"
    }

    /// Call once per refresh with the freshly observed `resetsAt` for a given
    /// provider+kind. A reset is only counted when the previously stored
    /// deadline has both changed *and* already passed — i.e. the window
    /// genuinely rolled over since it was last observed, not just that the
    /// server nudged the deadline forward mid-window.
    @discardableResult
    static func observe(provider: String, kind: String, resetsAt: Double?) -> Int {
        let defaults = UserDefaults.standard
        let countKey = countKey(provider: provider, kind: kind)
        let deadlineKey = lastDeadlineKey(provider: provider, kind: kind)
        var count = defaults.integer(forKey: countKey)

        guard let resetsAt else { return count }
        let previous = defaults.object(forKey: deadlineKey) as? Double

        if let previous, previous != resetsAt, previous <= Date().timeIntervalSince1970 {
            count += 1
            defaults.set(count, forKey: countKey)
        }
        if previous != resetsAt {
            defaults.set(resetsAt, forKey: deadlineKey)
        }
        return count
    }
}
