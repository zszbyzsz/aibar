import AppKit
import Foundation
import Security

/// Starts the bundled replacement helper, then terminates this process. The
/// helper is intentionally a second executable: macOS cannot safely replace a
/// running app bundle in place, particularly when it is launched by a login
/// item. It verifies the candidate after extraction and always relaunches the
/// existing app if replacement fails.
@MainActor
enum SelfUpdateInstaller {
    enum Error: LocalizedError {
        case noVerifiedPackage
        case notRunningFromAppBundle
        case unstableSigningIdentity
        case helperUnavailable
        case helperDidNotStart(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .noVerifiedPackage:
                return "The update package could not be verified."
            case .notRunningFromAppBundle:
                return "aibar is not running from an installed app bundle."
            case .unstableSigningIdentity:
                return "aibar is not signed with a stable Developer ID identity."
            case .helperUnavailable:
                return "The bundled update installer is missing."
            case .helperDidNotStart(let error):
                return error.localizedDescription
            }
        }
    }

    static func install(_ notice: AppUpdateNotice) throws {
        guard let archiveURL = notice.packageURL,
              FileManager.default.isReadableFile(atPath: archiveURL.path)
        else { throw Error.noVerifiedPackage }

        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app", appURL.deletingLastPathComponent().path != "/" else {
            throw Error.notRunningFromAppBundle
        }
        guard hasStableSigningIdentity(appURL) else {
            // Ad-hoc signatures contain a build-specific CDHash. Replacing
            // them would give macOS a new privacy identity and can reset TCC
            // grants, so do not begin an update that cannot meet the promise.
            throw Error.unstableSigningIdentity
        }
        guard let helperURL = Bundle.main.url(forResource: "aibarUpdateInstaller", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: helperURL.path)
        else { throw Error.helperUnavailable }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--archive", archiveURL.path,
            "--destination", appURL.path
        ]
        do {
            try process.run()
        } catch {
            throw Error.helperDidNotStart(error)
        }

        // A successful launch means the helper now owns both rollback and
        // relaunch. It waits for this process before touching the app bundle.
        NSApplication.shared.terminate(nil)
    }

    private static func hasStableSigningIdentity(_ appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        else { return false }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }

        var requirementString: CFString?
        guard SecRequirementCopyString(requirement, [], &requirementString) == errSecSuccess,
              let requirementString
        else { return false }
        return !(requirementString as String).localizedCaseInsensitiveContains("cdhash")
    }

    static func userMessage(for error: Swift.Error, language: AppLanguage) -> String {
        if case Error.notRunningFromAppBundle = error {
            return language == .zh
                ? "请先将 aibar.app 安装到“应用程序”或 ~/Applications 后再试。"
                : "Install aibar.app in Applications or ~/Applications, then try again."
        }
        if case Error.noVerifiedPackage = error {
            return language == .zh
                ? "此版本没有可校验的更新包。请前往发布页手动更新。"
                : "This release has no verifiable update package. Update from the release page instead."
        }
        if case Error.unstableSigningIdentity = error {
            return language == .zh
                ? "当前版本使用临时签名，自动更新会重置 macOS 隐私身份。请安装用同一 Developer ID 签名的正式版后再试。"
                : "This build uses ad-hoc signing. Install a release signed with the same Developer ID before using automatic updates."
        }
        return language == .zh
            ? "更新助手不可用。请重新下载完整的 aibar.app 后重试。"
            : "The update helper is unavailable. Reinstall the complete aibar.app and try again."
    }
}
