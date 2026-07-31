import Foundation
import Darwin

/// Reads account-only usage metadata through Codex's public app-server
/// protocol. This deliberately asks Codex itself to authenticate the request:
/// aibar never reads, copies, logs, or persists the OAuth access token.
///
/// The local JSONL transcripts expose automatic quota-window deadlines, but
/// not earned Full reset credits. `account/rateLimits/read` is the authoritative
/// source for their available count and expiry details.
enum CodexAppServerUsage {
    private static let initializeRequestID = 1
    private static let rateLimitsRequestID = 2
    /// A hard backstop for an unavailable or incompatible Codex process. The
    /// request normally completes in about two seconds and never blocks UI.
    private static let timeout: TimeInterval = 15

    static func fetchResetCredits() async -> RateLimitResetCredits? {
        await Task.detached(priority: .utility) {
            fetchResetCreditsSynchronously()
        }.value
    }

    private static func fetchResetCreditsSynchronously() -> RateLimitResetCredits? {
        guard let executableURL = codexExecutableURL() else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        // App-server warnings do not carry useful account data and can include
        // machine paths. Keep them out of aibar's own logs and UI.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // A stale/older Codex binary may exit before it accepts the second
        // request. macOS normally turns a write to that closed pipe into a
        // process-wide SIGPIPE, which must not take aibar down merely because
        // optional reset metadata was unavailable. F_SETNOSIGPIPE converts it
        // into the ordinary write error handled by `send` below.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWork
        )

        defer {
            timeoutWork.cancel()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        guard send([
            "id": initializeRequestID,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "aibar", "version": appVersion],
                "capabilities": ["experimentalApi": true],
            ],
        ], to: input.fileHandleForWriting) else { return nil }

        var reader = JSONLineReader(handle: output.fileHandleForReading)
        guard reader.readResponse(requestID: initializeRequestID) != nil else { return nil }

        guard send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting),
              send([
                "id": rateLimitsRequestID,
                "method": "account/rateLimits/read",
                "params": [:],
              ], to: input.fileHandleForWriting)
        else { return nil }

        guard let response = reader.readResponse(requestID: rateLimitsRequestID) else { return nil }
        return parseResetCreditsResponse(response, requestID: rateLimitsRequestID)
    }

    /// Kept internal so the protocol's optional/count-only/detail-rich shapes
    /// can be covered without starting a real account session in unit tests.
    static func parseResetCreditsResponse(
        _ data: Data,
        requestID: Int = rateLimitsRequestID
    ) -> RateLimitResetCredits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["id"] as? NSNumber)?.intValue == requestID,
              let result = root["result"] as? [String: Any],
              let summary = result["rateLimitResetCredits"] as? [String: Any],
              let count = (summary["availableCount"] as? NSNumber)?.intValue
        else { return nil }

        let expiries = (summary["credits"] as? [[String: Any]] ?? []).compactMap { credit -> Double? in
            guard credit["status"] as? String == "available" else { return nil }
            return (credit["expiresAt"] as? NSNumber)?.doubleValue
        }
        return RateLimitResetCredits(
            availableCount: max(0, count),
            expiresAt: expiries.sorted()
        )
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    /// GUI applications receive a deliberately small PATH, so check the
    /// first-party app bundles and common CLI install locations explicitly in
    /// addition to any executable already present on PATH.
    private static func codexExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["CODEX_EXECUTABLE"] { candidates.append(override) }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]

        return candidates.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}

/// Minimal newline-delimited JSON reader for the app-server stdio transport.
/// It ignores notifications and returns only the requested response envelope.
private struct JSONLineReader {
    let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func readResponse(requestID: Int) -> Data? {
        while let line = readLine() {
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (root["id"] as? NSNumber)?.intValue == requestID
            else { continue }
            return line
        }
        return nil
    }

    private mutating func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }

            // `read(upToCount:)` may wait for the requested byte count on a
            // pipe. App-server's initialize response is intentionally small,
            // so asking for a 4 KiB chunk can deadlock until our timeout even
            // though a complete JSON line is already waiting. `availableData`
            // blocks only until some bytes arrive, then returns that response.
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }
}
