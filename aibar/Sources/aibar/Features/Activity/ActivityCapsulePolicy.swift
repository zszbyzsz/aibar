import Foundation

/// A completed task retained in the capsule's short-lived history shelf.
/// This is intentionally runtime-only state; nothing about task activity is
/// persisted after aibar exits.
struct RetainedCompletion: Equatable {
    let key: String
    let project: String
    let outcome: ActivityOutcome
    let completedAt: Date

    var row: CapsuleRow {
        CapsuleRow(
            id: "completed-\(key)",
            threadID: key,
            display: .completed(project: project, outcome: outcome)
        )
    }
}

/// Pure ordering and lifetime rules for the activity capsule. Keeping these
/// rules independent from `NSPanel` makes the two-stage completion behavior
/// deterministic and directly testable.
enum ActivityCapsulePolicy {
    /// Once its five-second announcement ends, a completed task remains at
    /// the end of the running list for at most two minutes.
    static let completionRetentionDuration: TimeInterval = 2 * 60

    static func retainedCompletions(
        from completions: [RetainedCompletion],
        now: Date,
        hasRunningProjects: Bool
    ) -> [RetainedCompletion] {
        guard hasRunningProjects else { return [] }
        return completions
            .filter { now.timeIntervalSince($0.completedAt) < completionRetentionDuration }
            .sorted { $0.completedAt < $1.completedAt }
    }

    /// The announcement temporarily occupies the first collapsed slot. The
    /// running projects follow it, and retained completions sit at the very
    /// end without duplicating the task currently being announced.
    static func rows(
        running: [CapsuleRow],
        announcement: RetainedCompletion?,
        retained: [RetainedCompletion],
        updateNotice: AppUpdateNotice? = nil
    ) -> [CapsuleRow] {
        var rows: [CapsuleRow] = []
        if let announcement {
            rows.append(announcement.row)
        }
        rows.append(contentsOf: running)
        rows.append(contentsOf: retained.lazy
            .filter { $0.key != announcement?.key }
            .map(\.row))
        // An update should not summon an otherwise-idle capsule on its own.
        // It joins the tail only while task activity already makes the panel
        // visible, matching the completion-history reminder language.
        if !rows.isEmpty, let updateNotice {
            rows.append(CapsuleRow(
                id: "update-\(updateNotice.version)",
                threadID: nil,
                display: .update(updateNotice)
            ))
        }
        return rows
    }
}
