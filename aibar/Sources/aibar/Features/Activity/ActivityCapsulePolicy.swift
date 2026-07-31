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
/// rules independent from `NSPanel` makes its running, retained-completion,
/// and all-completed states deterministic and directly testable.
enum ActivityCapsulePolicy {
    /// Once its five-second announcement ends, a completed task remains at
    /// the end of the running list for at most two minutes.
    static let completionRetentionDuration: TimeInterval = 2 * 60
    /// Once every running task has finished, the final completion state stays
    /// visible long enough to be noticed without becoming permanent chrome.
    static let allCompletedRetentionDuration: TimeInterval = 30

    static func retainedCompletions(
        from completions: [RetainedCompletion],
        now: Date,
        hasRunningProjects: Bool
    ) -> [RetainedCompletion] {
        let sorted = completions.sorted { $0.completedAt < $1.completedAt }
        guard hasRunningProjects else { return sorted }
        return sorted.filter { now.timeIntervalSince($0.completedAt) < completionRetentionDuration }
    }

    /// While work is running, the announcement occupies the first slot and
    /// retained completions sit at the end. Once all work finishes, one item
    /// remains directly actionable while multiple items collapse to a summary
    /// whose detail rows are only returned during explicit review.
    static func rows(
        running: [CapsuleRow],
        announcement: RetainedCompletion?,
        retained: [RetainedCompletion],
        completionReviewExpanded: Bool = false,
        updateNotice: AppUpdateNotice? = nil
    ) -> [CapsuleRow] {
        var rows: [CapsuleRow] = []
        if running.isEmpty, !retained.isEmpty {
            if retained.count == 1, !completionReviewExpanded {
                rows.append(retained[0].row)
            } else {
                rows.append(CapsuleRow(
                    id: "completion-summary",
                    threadID: nil,
                    display: .completionSummary(count: retained.count)
                ))
                if completionReviewExpanded {
                    rows.append(contentsOf: retained.map(\.row))
                }
            }
        } else {
            if let announcement {
                rows.append(announcement.row)
            }
            rows.append(contentsOf: running)
            rows.append(contentsOf: retained.lazy
                .filter { $0.key != announcement?.key }
                .map(\.row))
        }
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
