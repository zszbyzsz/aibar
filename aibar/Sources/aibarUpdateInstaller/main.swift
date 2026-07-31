import AppKit
import Darwin
import Foundation
import Security

/// A short-lived process that safely swaps in a downloaded application after
/// its parent has quit. It never copies TCC records: macOS retains existing
/// privacy consent when the candidate has the same bundle ID and designated
/// code-signing requirement. Any other candidate is rejected and the original
/// app is relaunched unchanged.
@main
struct AibarUpdateInstaller {
    static func main() {
        guard let arguments = Arguments(CommandLine.arguments.dropFirst()) else { return }
        waitForParentToExit(arguments.parentPID)

        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("aibar-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try extract(archive: arguments.archiveURL, into: stagingURL)
            let candidateURL = try candidateApp(in: stagingURL)
            try validate(candidate: candidateURL, replacing: arguments.destinationURL)
            try replace(destination: arguments.destinationURL, with: candidateURL)
            relaunch(arguments.destinationURL)
        } catch {
            // Replacement is transactional: `replace` restores the existing
            // bundle if moving the new one fails. Relaunch it for every other
            // error too, so a failed update never leaves a menu-bar app gone.
            relaunch(arguments.destinationURL)
        }
    }

    private struct Arguments {
        let parentPID: pid_t
        let archiveURL: URL
        let destinationURL: URL

        init?(_ values: ArraySlice<String>) {
            var pairs: [String: String] = [:]
            var index = values.startIndex
            while index < values.endIndex {
                let key = values[index]
                let valueIndex = values.index(after: index)
                guard valueIndex < values.endIndex else { return nil }
                pairs[key] = values[valueIndex]
                index = values.index(after: valueIndex)
            }
            guard let rawPID = pairs["--parent-pid"], let pid = pid_t(rawPID),
                  let archive = pairs["--archive"], let destination = pairs["--destination"]
            else { return nil }
            parentPID = pid
            archiveURL = URL(fileURLWithPath: archive).standardizedFileURL
            destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
        }
    }

    private static func waitForParentToExit(_ parentPID: pid_t) {
        // `kill(pid, 0)` is a read-only existence check. A bounded wait avoids
        // a permanently orphaned helper should the parent somehow remain alive.
        for _ in 0..<200 where kill(parentPID, 0) == 0 {
            usleep(100_000)
        }
    }

    private static func extract(archive: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallerError.extractionFailed }
    }

    private static func candidateApp(in directory: URL) throws -> URL {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "app" }
        guard candidates.count == 1 else { throw InstallerError.invalidArchive }
        return candidates[0]
    }

    private static func validate(candidate: URL, replacing installed: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: installed.path),
              Bundle(url: candidate)?.bundleIdentifier == Bundle(url: installed)?.bundleIdentifier
        else { throw InstallerError.bundleIdentityMismatch }

        let installedRequirement = try designatedRequirement(of: installed)
        let candidateRequirement = try designatedRequirement(of: candidate)
        guard installedRequirement == candidateRequirement else {
            // An ad-hoc signature includes a per-build CDHash, so it fails
            // this comparison by design. Users must install a Developer ID
            // signed build before a privacy-preserving automatic update.
            throw InstallerError.signingIdentityMismatch
        }
    }

    private static func designatedRequirement(of appURL: URL) throws -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        else { throw InstallerError.invalidSignature }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement
        else { throw InstallerError.invalidSignature }

        var requirementString: CFString?
        guard SecRequirementCopyString(requirement, [], &requirementString) == errSecSuccess,
              let requirementString
        else { throw InstallerError.invalidSignature }
        return requirementString as String
    }

    private static func replace(destination: URL, with candidate: URL) throws {
        let fileManager = FileManager.default
        let backup = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".aibar-backup-\(UUID().uuidString).app", isDirectory: true)
        var movedOriginal = false
        do {
            try fileManager.moveItem(at: destination, to: backup)
            movedOriginal = true
            try fileManager.moveItem(at: candidate, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            if movedOriginal, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func relaunch(_ appURL: URL) {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    private enum InstallerError: Swift.Error {
        case extractionFailed
        case invalidArchive
        case bundleIdentityMismatch
        case signingIdentityMismatch
        case invalidSignature
    }
}
