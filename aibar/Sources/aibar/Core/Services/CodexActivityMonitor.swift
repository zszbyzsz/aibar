import Foundation
import SQLite3

/// Reads only safe thread-index metadata from Codex Desktop's local SQLite
/// database. The database also contains titles and message previews, but this
/// monitor intentionally never selects them. A short tail read of the active
/// thread's JSONL determines the activity phase without retaining content.
struct CodexActivityMonitor {
    /// A thread with no index update for this long is treated as idle. This is
    /// intentionally an activity indicator, not a claim about an exact percent
    /// complete: Codex does not persist a trustworthy task-progress fraction.
    static let activeWindow: TimeInterval = 120

    private let databaseURL: URL
    private let rolloutStartCache = RolloutStartCache()

    private enum GoalTimingEvent {
        case active(startedAt: Date)
        case inactive
    }

    private struct RolloutTimingScan {
        var taskStartedAt: Date?
        var goalEvent: GoalTimingEvent?
    }

    private struct ActivityTiming {
        let startedAt: Date
        let scope: ProjectActivity.TimingScope
    }

    /// Polling happens on detached utility tasks. Cache the last resolved turn
    /// boundary per rollout so an old, multi-megabyte thread is scanned once;
    /// later polls only inspect bytes appended since that scan.
    private final class RolloutStartCache: @unchecked Sendable {
        private struct Entry {
            let fileSize: UInt64
            let taskStartedAt: Date?
            let goalStartedAt: Date?
        }

        private var entries: [String: Entry] = [:]
        private let lock = NSLock()

        func activityTiming(path: String, handle: FileHandle, fileSize: UInt64) -> ActivityTiming? {
            lock.lock()
            defer { lock.unlock() }

            let previous = entries[path]
            if previous?.fileSize == fileSize {
                return Self.resolvedTiming(from: previous)
            }

            // If the file only grew, the previous result remains valid unless
            // the appended region contains a newer task or Goal boundary.
            // Include the old trailing newline so the first new JSONL record
            // is complete.
            let scanFloor: UInt64
            if let previous, fileSize > previous.fileSize {
                scanFloor = previous.fileSize > 0 ? previous.fileSize - 1 : 0
            } else {
                scanFloor = 0
            }
            let scan = CodexActivityMonitor.rolloutTimingScan(
                in: handle,
                fileSize: fileSize,
                scanFloor: scanFloor
            )
            let taskStartedAt = scan.taskStartedAt
                ?? (scanFloor > 0 ? previous?.taskStartedAt : nil)
            let goalStartedAt: Date?
            if let goalEvent = scan.goalEvent {
                switch goalEvent {
                case .active(let startedAt): goalStartedAt = startedAt
                case .inactive: goalStartedAt = nil
                }
            } else {
                goalStartedAt = scanFloor > 0 ? previous?.goalStartedAt : nil
            }
            entries[path] = Entry(
                fileSize: fileSize,
                taskStartedAt: taskStartedAt,
                goalStartedAt: goalStartedAt
            )
            return Self.resolvedTiming(from: entries[path])
        }

        private static func resolvedTiming(from entry: Entry?) -> ActivityTiming? {
            if let startedAt = entry?.goalStartedAt {
                return ActivityTiming(startedAt: startedAt, scope: .continuousGoal)
            }
            if let startedAt = entry?.taskStartedAt {
                return ActivityTiming(startedAt: startedAt, scope: .currentTurn)
            }
            return nil
        }
    }

    init() {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
    }

    /// Kept for the hover dashboard (`UsageStore`), which only ever needs the
    /// "is something active right now" case — see `currentState(now:)` for
    /// the fuller picture (including *why* a run ended) that the always-on
    /// capsule needs to pick a completion sound.
    func currentActivity(now: Date = Date()) -> ProjectActivity? {
        if case .active(let activity) = currentState(now: now) { return activity }
        return nil
    }

    /// The single most recently updated thread's state — what the hover
    /// dashboard cares about. Equivalent to `activeThreadStates(limit: 1)`'s
    /// only entry, or `.idle(nil)` when there's no thread at all.
    func currentState(now: Date = Date()) -> CodexActivityState {
        activeThreadStates(now: now, limit: 1).first?.state ?? .idle(nil)
    }

    /// One tracked thread's resolved state, keyed by the thread's own
    /// database id so a caller watching many threads at once (the always-on
    /// capsule, which can have several Codex projects running in parallel)
    /// can tell which specific thread each state belongs to across polls.
    struct ThreadActivity {
        let key: String
        let state: CodexActivityState
    }

    /// One row of the `threads` table, narrowed to the columns this monitor
    /// is willing to look at.
    private struct ThreadRow {
        let id: String
        let cwd: String
        let model: String?
        let tokensUsed: Int
        let updatedAt: Date?
        let createdAt: Date?
        let sandboxPolicy: String
        let approvalMode: String
        let rolloutPath: String?
        /// `threads.thread_source` is `subagent` for a thread Codex spawned
        /// on its own behalf, and `user` for one a person actually started.
        /// Only the clean discriminator is read — never the sibling `source`
        /// column, which carries the sub-agent's path and nickname.
        let isSubagent: Bool
    }

    /// Up to `limit` of the most recently updated non-archived *conversations*,
    /// each resolved the same way a single thread is resolved below.
    ///
    /// A conversation is deliberately not the same thing as a thread. Codex
    /// spawns sub-agents as their own `threads` rows, each with its own
    /// rollout that ends with its own `task_complete` — so treating every row
    /// as a project meant one conversation appeared as half a dozen
    /// simultaneous "projects", and each sub-agent finishing announced that
    /// the *project* had completed while the conversation it belonged to was
    /// still working. Sub-agent rows are therefore never reported on their
    /// own; they're folded into the conversation that spawned them (see
    /// `conversationState(for:)`), which stays running until both it and its
    /// delegates are done.
    ///
    /// Unlike `currentState`/`currentActivity` (which only ever look at the
    /// single most recent conversation, matching the hover dashboard's
    /// "current activity" widget), this lets the always-on capsule track
    /// several concurrent conversations and let each finish independently.
    func activeThreadStates(now: Date = Date(), limit: Int32 = 12) -> [ThreadActivity] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { return [] }
        defer { sqlite3_close(database) }

        // Fetched with headroom over `limit`, since the rows come back mixed:
        // the sub-agent rows interleaved among the conversations are needed to
        // resolve them but never reported themselves. Sub-agents old enough to
        // fall outside this window are also old enough that
        // `conversationState(for:)` would skip them as stale anyway.
        let rows = threadRows(database: database, limit: max(limit * 5, 60))
        guard !rows.isEmpty else { return [] }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childIDsByParent = spawnEdges(database: database)

        var results: [ThreadActivity] = []
        for row in rows where !row.isSubagent {
            guard results.count < Int(limit) else { break }
            results.append(ThreadActivity(
                key: row.id,
                state: conversationState(for: row, rowsByID: rowsByID,
                                         childIDsByParent: childIDsByParent, now: now)
            ))
        }
        return results
    }

    /// Resolves one conversation by combining its own rollout with those of
    /// every sub-agent beneath it. The conversation counts as running while
    /// *anything* under it is running, so a parent whose own rollout has
    /// reached a `task_complete` while its delegates keep working is still
    /// reported active rather than announcing a completion the user would
    /// rightly read as wrong.
    private func conversationState(
        for row: ThreadRow,
        rowsByID: [String: ThreadRow],
        childIDsByParent: [String: [String]],
        now: Date
    ) -> CodexActivityState {
        let ownSnapshot = rolloutSnapshot(forRolloutAt: row.rolloutPath)
        let ownOutcome = ownSnapshot.outcome
        var lastActivity = row.updatedAt ?? .distantPast
        var delegateWorking = false

        for child in descendants(of: row.id, childIDsByParent: childIDsByParent, rowsByID: rowsByID) {
            guard let childUpdated = child.updatedAt else { continue }
            lastActivity = max(lastActivity, childUpdated)
            // A sub-agent that hasn't touched its own row within the activity
            // window can't be what's keeping this conversation alive, and
            // skipping it keeps the per-poll rollout reads bounded to the
            // handful of delegates that are genuinely live.
            guard now.timeIntervalSince(childUpdated) <= Self.activeWindow else { continue }
            if case .active = rolloutSnapshot(
                forRolloutAt: child.rolloutPath,
                resolveTiming: false
            ).outcome {
                delegateWorking = true
            }
        }

        let withinWindow = now.timeIntervalSince(lastActivity) <= Self.activeWindow
        func activity(phase: ProjectActivity.Phase) -> ProjectActivity {
            ProjectActivity(
                project: (row.cwd as NSString).lastPathComponent.isEmpty
                    ? row.cwd : (row.cwd as NSString).lastPathComponent,
                model: row.model,
                phase: phase,
                lastActivityAt: lastActivity,
                // Threads survive across many submitted tasks. Measuring from
                // `created_at_ms` made a newly submitted task in an old thread
                // immediately appear hours or days old.
                startedAt: ownSnapshot.startedAt ?? row.createdAt ?? lastActivity,
                timingScope: ownSnapshot.timingScope,
                // Falls back to the database's `tokens_used`, which is a
                // lifetime cumulative sum across every turn ever sent for
                // this thread (often tens of millions of tokens) — not the
                // conversation's actual current context size. That fallback
                // only fires before the rollout's first `token_count` event
                // has landed.
                sessionTokens: ownSnapshot.contextTokens ?? row.tokensUsed,
                sandboxPolicy: row.sandboxPolicy,
                approvalMode: row.approvalMode,
                threadID: row.id
            )
        }

        switch ownOutcome {
        case .active(let phase) where withinWindow:
            return .active(activity(phase: phase))
        case .active:
            // The rollout's last event still looks mid-task, but nothing has
            // updated in over `activeWindow` — Codex went quiet without an
            // explicit end signal (a long-silent tool call, or the app simply
            // closed). Reported as "paused" rather than "completed".
            return .idle(.timedOut)
        case .ended(let reason):
            // The conversation's own turn has wrapped up, but it's waiting on
            // sub-agents it dispatched — still working, from the only point of
            // view a viewer has.
            if delegateWorking && withinWindow { return .active(activity(phase: .usingTool)) }
            return .idle(reason)
        }
    }

    /// Every sub-agent beneath `id`, transitively — sub-agents can spawn their
    /// own. `visited` guards against a cycle in the edge table rather than
    /// trusting it to be a strict tree.
    private func descendants(
        of id: String,
        childIDsByParent: [String: [String]],
        rowsByID: [String: ThreadRow]
    ) -> [ThreadRow] {
        var found: [ThreadRow] = []
        var visited: Set<String> = [id]
        var queue = childIDsByParent[id] ?? []
        while let next = queue.popLast() {
            guard visited.insert(next).inserted else { continue }
            if let row = rowsByID[next] { found.append(row) }
            queue.append(contentsOf: childIDsByParent[next] ?? [])
        }
        return found
    }

    /// `recency_at_ms` tracks when a thread was last opened/focused in the
    /// Codex Desktop UI, not when it last actually did anything — a thread
    /// that's been running untouched in the background can sit minutes
    /// "stale" by that column while `updated_at_ms` ticks in real time.
    /// Ordering and freshness both need to key off `updated_at_ms`, or this
    /// monitor picks whichever thread a human last clicked on instead of
    /// whichever one Codex is actually working on right now.
    private func threadRows(database: OpaquePointer, limit: Int32) -> [ThreadRow] {
        let query = """
        SELECT cwd, model, tokens_used, updated_at_ms, sandbox_policy, approval_mode,
               rollout_path, created_at_ms, id, thread_source
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at_ms DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, limit)

        var rows: [ThreadRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // The thread's own primary key doubles as this monitor's tracking
            // key and as the id the always-on capsule deep-links to
            // (`codex://threads/<id>`) — a thread somehow missing one (should
            // never happen; the column is `PRIMARY KEY`) can't be tracked or
            // linked to, so it's skipped rather than given a synthetic key.
            guard let cwd = text(column: 0, statement: statement),
                  let threadID = text(column: 8, statement: statement)
            else { continue }
            rows.append(ThreadRow(
                id: threadID,
                cwd: cwd,
                model: text(column: 1, statement: statement),
                tokensUsed: Int(sqlite3_column_int64(statement, 2)),
                updatedAt: date(column: 3, statement: statement),
                createdAt: date(column: 7, statement: statement),
                sandboxPolicy: text(column: 4, statement: statement) ?? "",
                approvalMode: text(column: 5, statement: statement) ?? "",
                rolloutPath: text(column: 6, statement: statement),
                // Anything that isn't explicitly flagged a sub-agent counts as
                // a conversation, so rows predating the column (where it reads
                // empty) keep showing up rather than silently vanishing.
                isSubagent: text(column: 9, statement: statement) == "subagent"
            ))
        }
        return rows
    }

    /// `thread_spawn_edges` as a parent → children map. Edges are read
    /// regardless of their `status`, because a delegate's liveness is decided
    /// from its own rollout below; `status` only records whether Codex ever
    /// closed the edge out, and a stale `open` on a long-finished sub-agent
    /// would otherwise keep a conversation pinned as running forever.
    private func spawnEdges(database: OpaquePointer) -> [String: [String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges", -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        var edges: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let parent = text(column: 0, statement: statement),
                  let child = text(column: 1, statement: statement)
            else { continue }
            edges[parent, default: []].append(child)
        }
        return edges
    }

    private func text(column: Int32, statement: OpaquePointer) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func date(column: Int32, statement: OpaquePointer) -> Date? {
        let milliseconds = sqlite3_column_int64(statement, column)
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private enum RolloutOutcome {
        case active(ProjectActivity.Phase)
        case ended(ActivityOutcome)
    }

    /// Only event type labels (and, for `token_count` events, the token
    /// counters — never the prompt/response bodies they're attached to) are
    /// inspected; message bodies and tool payloads are never surfaced or
    /// cached.
    ///
    /// Returns the phase/outcome alongside the conversation's current
    /// context-window occupancy, i.e. `last_token_usage.total_tokens` off
    /// the most recent `token_count` event in the tail — how many tokens the
    /// *next* turn's prompt would actually carry. This is deliberately not
    /// `total_token_usage`, which the same event reports right alongside it:
    /// that field is a lifetime sum across every turn this thread has ever
    /// sent, grows without bound over a long session, and does not reflect
    /// what's actually sitting in context right now.
    private func rolloutSnapshot(
        forRolloutAt path: String?,
        resolveTiming: Bool = true
    ) -> (
        outcome: RolloutOutcome,
        contextTokens: Int?,
        startedAt: Date?,
        timingScope: ProjectActivity.TimingScope
    ) {
        guard let path, FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return (.active(.working), nil, nil, .currentTurn) }
        defer { try? handle.close() }

        let tailSize: UInt64 = 64 * 1_024
        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: fileSize > tailSize ? fileSize - tailSize : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return (.active(.working), nil, nil, .currentTurn)
        }

        var resolvedOutcome: RolloutOutcome?
        var contextTokens: Int?

        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any]
            let topLevelType = object["type"] as? String
            let payloadType = payload?["type"] as? String
            let type = payloadType ?? topLevelType

            if contextTokens == nil, type == "token_count",
               let info = payload?["info"] as? [String: Any],
               let lastUsage = info["last_token_usage"] as? [String: Any],
               let total = lastUsage["total_tokens"] as? Int {
                contextTokens = total
            }

            if resolvedOutcome == nil {
                switch type {
                case "task_complete":
                    resolvedOutcome = .ended(.completed)
                case "turn_aborted":
                    resolvedOutcome = .ended(.aborted)
                case "patch_apply_end":
                    resolvedOutcome = .active(.editing)
                case "custom_tool_call", "function_call", "mcp_tool_call_end", "tool_search_call", "web_search_call":
                    resolvedOutcome = .active(.usingTool)
                case "agent_reasoning", "reasoning":
                    resolvedOutcome = .active(.thinking)
                case "task_started", "token_count", "agent_message", "response_item":
                    resolvedOutcome = .active(.working)
                default:
                    break
                }
            }

            if resolvedOutcome != nil, contextTokens != nil { break }
        }
        let outcome = resolvedOutcome ?? .active(.working)
        guard resolveTiming else {
            return (outcome, contextTokens, nil, .currentTurn)
        }
        // Resolve timing even when the parent's own turn has just completed:
        // the conversation can still be active while one of its delegates is
        // running, and that row must retain the parent task/Goal clock rather
        // than falling all the way back to the thread creation timestamp.
        let timing = rolloutStartCache.activityTiming(
            path: path,
            handle: handle,
            fileSize: fileSize
        )
        return (
            outcome,
            contextTokens,
            timing?.startedAt,
            timing?.scope ?? .currentTurn
        )
    }

    /// Finds the current task's start without assuming it is inside the small
    /// activity tail above. A single long response can put `task_started`
    /// hundreds of kilobytes behind EOF, while the thread itself may be days
    /// old. Reading backward in bounded chunks avoids loading a large rollout
    /// all at once.
    static func latestTaskStartedAt(inRolloutAt path: String) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        return rolloutTimingScan(in: handle, fileSize: fileSize, scanFloor: 0).taskStartedAt
    }

    /// Goal runs can span dozens of automatic Codex turns. Their persisted
    /// `timeUsedSeconds` is active runtime (paused intervals excluded), so an
    /// equivalent start instant is `updatedAt - timeUsedSeconds`. Views can
    /// keep using a normal ticking `now - startedAt` clock while goal rows show
    /// the whole run and ordinary rows still start at the latest task turn.
    static func activityStartedAt(inRolloutAt path: String) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let scan = rolloutTimingScan(in: handle, fileSize: fileSize, scanFloor: 0)
        if case .active(let startedAt) = scan.goalEvent { return startedAt }
        return scan.taskStartedAt
    }

    private static func rolloutTimingScan(
        in handle: FileHandle,
        fileSize: UInt64,
        scanFloor: UInt64
    ) -> RolloutTimingScan {
        let chunkSize: UInt64 = 64 * 1_024
        let taskMarker = Data(#""task_started""#.utf8)
        let goalUpdatedMarker = Data(#""thread_goal_updated""#.utf8)
        let goalClearedMarker = Data(#""thread_goal_cleared""#.utf8)
        var upperBound = fileSize
        var newerLineFragment = Data()
        var result = RolloutTimingScan()

        while upperBound > scanFloor {
            let lowerBound = upperBound - scanFloor > chunkSize ? upperBound - chunkSize : scanFloor
            try? handle.seek(toOffset: lowerBound)
            guard var chunk = try? handle.read(upToCount: Int(upperBound - lowerBound)) else { return result }
            chunk.append(newerLineFragment)

            let lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstLineIsPartial = lowerBound > scanFloor
            let completeLines = firstLineIsPartial ? lines.dropFirst() : lines[...]

            for line in completeLines.reversed() {
                let mightContainTask = result.taskStartedAt == nil && line.range(of: taskMarker) != nil
                let mightContainGoal = result.goalEvent == nil
                    && (line.range(of: goalUpdatedMarker) != nil || line.range(of: goalClearedMarker) != nil)
                guard mightContainTask || mightContainGoal,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let type = payload["type"] as? String
                else { continue }

                if result.taskStartedAt == nil, type == "task_started" {
                    if let seconds = payload["started_at"] as? NSNumber, seconds.doubleValue > 0 {
                        result.taskStartedAt = Date(timeIntervalSince1970: seconds.doubleValue)
                    } else if let timestamp = object["timestamp"] as? String {
                        result.taskStartedAt = Formatting.parseISODate(timestamp)
                    }
                }

                if result.goalEvent == nil, type == "thread_goal_cleared" {
                    result.goalEvent = .inactive
                } else if result.goalEvent == nil, type == "thread_goal_updated" {
                    guard let goal = payload["goal"] as? [String: Any],
                          goal["status"] as? String == "active"
                    else {
                        result.goalEvent = .inactive
                        continue
                    }
                    let timeUsed = max(0, (goal["timeUsedSeconds"] as? NSNumber)?.doubleValue ?? 0)
                    let updatedAt: Date?
                    if let seconds = goal["updatedAt"] as? NSNumber {
                        updatedAt = Date(timeIntervalSince1970: seconds.doubleValue)
                    } else {
                        updatedAt = (object["timestamp"] as? String).flatMap(Formatting.parseISODate)
                    }
                    if let updatedAt {
                        result.goalEvent = .active(startedAt: updatedAt.addingTimeInterval(-timeUsed))
                    } else {
                        result.goalEvent = .inactive
                    }
                }

                if result.taskStartedAt != nil, result.goalEvent != nil { return result }
            }

            if firstLineIsPartial, let first = lines.first {
                newerLineFragment = Data(first)
            } else {
                newerLineFragment.removeAll(keepingCapacity: true)
            }
            upperBound = lowerBound
        }
        return result
    }
}
