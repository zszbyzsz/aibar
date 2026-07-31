import CryptoKit
import Foundation

/// Checks the repository's latest GitHub Release and downloads only assets
/// whose GitHub-provided SHA-256 digest can be verified locally. Installation
/// is deliberately handled by `SelfUpdateInstaller`: replacing an app is safe
/// only after it confirms that the new bundle has the same stable signing
/// identity as the app the user originally authorised.
@MainActor
final class AppUpdateService {
    nonisolated static let checkInterval: TimeInterval = 6 * 60 * 60
    nonisolated static let repositoryLatestReleaseURL = URL(
        string: "https://api.github.com/repos/zszbyzsz/aibar/releases/latest"
    )!

    private let currentVersion: String
    private let onNoticeChange: @MainActor (AppUpdateNotice?) -> Void
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    /// Interactive checks that arrive while the launch/background request is
    /// still in flight. Coalescing them avoids duplicate network work while
    /// ensuring a user click always receives a result.
    private var pendingCompletions: [@MainActor (CheckResult) -> Void] = []

    init(currentVersion: String, onNoticeChange: @escaping @MainActor (AppUpdateNotice?) -> Void) {
        self.currentVersion = currentVersion
        self.onNoticeChange = onNoticeChange
    }

    deinit {
        timer?.invalidate()
        checkTask?.cancel()
    }

    func start() {
        checkNow()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNow() }
        }
        // Update checks are background maintenance, so give the run loop room
        // to coalesce this wake-up with other work.
        timer.tolerance = 5 * 60
        self.timer = timer
    }

    enum CheckResult {
        case updateAvailable(AppUpdateNotice)
        case upToDate
        case failed
    }

    func checkNow(completion: (@MainActor (CheckResult) -> Void)? = nil) {
        // A menu click made while the background launch check is running must
        // not start a second download of the same archive. Its completion is
        // attached to the existing request so the menu action is never silent.
        if let completion { pendingCompletions.append(completion) }
        guard checkTask == nil else { return }
        let currentVersion = currentVersion
        checkTask = Task { @MainActor [weak self] in
            do {
                let notice = try await Self.fetchLatestNotice(currentVersion: currentVersion)
                guard !Task.isCancelled else { return }
                self?.checkTask = nil
                self?.onNoticeChange(notice)
                self?.finishChecks(with: notice.map(CheckResult.updateAvailable) ?? .upToDate)
            } catch {
                // A transient offline/API failure must not erase a previously
                // discovered update. The next six-hour check retries quietly.
                self?.checkTask = nil
                self?.finishChecks(with: .failed)
            }
        }
    }

    private func finishChecks(with result: CheckResult) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    nonisolated static func fetchLatestNotice(
        currentVersion: String,
        session: URLSession = .shared
    ) async throws -> AppUpdateNotice? {
        var request = URLRequest(url: repositoryLatestReleaseURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("aibar-update-checker", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              let installed = AppVersion(currentVersion),
              let latest = AppVersion(release.tagName),
              installed < latest
        else { return nil }

        let displayVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let packageURL = try await pullVerifiedArchive(
            for: release,
            displayVersion: displayVersion,
            session: session
        )
        return AppUpdateNotice(
            version: displayVersion,
            releaseURL: release.htmlURL,
            packageURL: packageURL
        )
    }

    /// Downloads only an archive whose digest is supplied by GitHub. Missing
    /// digest metadata degrades to a release-page reminder instead of trusting
    /// and executing an unverifiable package.
    nonisolated private static func pullVerifiedArchive(
        for release: GitHubRelease,
        displayVersion: String,
        session: URLSession
    ) async throws -> URL? {
        let expectedName = "aibar-\(displayVersion).zip"
        guard let asset = release.assets.first(where: { $0.name.caseInsensitiveCompare(expectedName) == .orderedSame })
                ?? release.assets.first(where: {
                    $0.name.localizedCaseInsensitiveContains("aibar")
                        && $0.name.lowercased().hasSuffix(".zip")
                }),
              let expectedDigest = asset.sha256Digest
        else { return nil }

        let destination = try updateArchiveURL(filename: asset.name)
        if FileManager.default.fileExists(atPath: destination.path),
           try sha256(of: destination) == expectedDigest {
            return destination
        }

        var request = URLRequest(url: asset.downloadURL)
        request.timeoutInterval = 5 * 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("aibar-update-checker", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.invalidResponse
        }
        guard try sha256(of: temporaryURL) == expectedDigest else {
            throw UpdateError.digestMismatch
        }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    nonisolated private static func updateArchiveURL(filename: String) throws -> URL {
        let cache = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cache
            .appendingPathComponent("com.aibar.app", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum UpdateError: Error {
        case invalidResponse
        case digestMismatch
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let downloadURL: URL
        let digest: String?

        var sha256Digest: String? {
            guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
            let value = String(digest.dropFirst("sha256:".count)).lowercased()
            guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
            return value
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
            case digest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

/// Numeric semantic-version ordering without relying on lexicographic string
/// comparison (`0.10.0` must be newer than `0.9.0`).
struct AppVersion: Comparable {
    private let components: [Int]
    private let prerelease: String?

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let withoutBuild = trimmed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? trimmed
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == pieces[0].split(separator: ".").count else { return nil }
        components = numbers
        prerelease = pieces.count > 1 ? pieces[1] : nil
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (.some, .none): return true
        case (.none, .some): return false
        case let (.some(left), .some(right)): return left.localizedStandardCompare(right) == .orderedAscending
        case (.none, .none): return false
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return false }
        }
        return lhs.prerelease == rhs.prerelease
    }
}
