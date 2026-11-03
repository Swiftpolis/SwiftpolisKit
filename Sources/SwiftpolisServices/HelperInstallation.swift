import Foundation
import SwiftpolisEngines

/// Where the helpers live, and keeping yt-dlp current. See docs/adr/0003-bundle-non-swift-helpers.md.
///
/// The bundled yt-dlp can't change, because the app is signed. Sites change often enough that it has
/// to, so a copy outside the app updates itself, with the bundled one to fall back on.
public struct HelperInstallation: Sendable {
    private static let updateInterval: TimeInterval = 24 * 60 * 60
    private static let ytDlpName = "yt-dlp"

    private let bundledFolder: URL
    private let supportFolder: URL

    public init(bundledFolder: URL, supportFolder: URL) {
        self.bundledFolder = bundledFolder
        self.supportFolder = supportFolder
    }

    private var bundledYtDlp: URL { bundledFolder.appending(path: Self.ytDlpName, directoryHint: .notDirectory) }
    private var copiedYtDlp: URL { supportFolder.appending(path: Self.ytDlpName, directoryHint: .notDirectory) }

    public var paths: HelperPaths {
        func executable(_ url: URL) -> String? {
            FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
        }
        return HelperPaths(
            ytDlp: executable(copiedYtDlp) ?? executable(bundledYtDlp),
            ffmpeg: executable(bundledFolder.appending(path: "ffmpeg", directoryHint: .notDirectory)),
            deno: executable(bundledFolder.appending(path: "deno", directoryHint: .notDirectory))
        )
    }

    /// Checks for a new yt-dlp at most once a day, and returns when it last checked. Whatever goes
    /// wrong, what's left is a yt-dlp that runs.
    public func updateIfDue(lastCheck: Date?, now: Date = Date()) async -> Date? {
        if let lastCheck, now.timeIntervalSince(lastCheck) < Self.updateInterval { return lastCheck }
        guard FileManager.default.isExecutableFile(atPath: bundledYtDlp.path) else { return lastCheck }

        await refreshCopy()
        guard FileManager.default.isExecutableFile(atPath: copiedYtDlp.path) else { return now }

        _ = await HelperProcess(path: copiedYtDlp.path, arguments: ["--ignore-config", "--update"]).run()
        if await version(of: copiedYtDlp) == nil {
            try? FileManager.default.removeItem(at: copiedYtDlp)
        }
        return now
    }

    /// Makes the copy if there isn't one, or if the app has brought a newer version than it holds.
    private func refreshCopy() async {
        if FileManager.default.isExecutableFile(atPath: copiedYtDlp.path) {
            let copied = await version(of: copiedYtDlp)
            let bundled = await version(of: bundledYtDlp)
            // These are dates, so they sort as text.
            if let copied, let bundled, copied >= bundled { return }
        }
        copyBundled()
    }

    private func copyBundled() {
        let manager = FileManager.default
        let temporary = supportFolder.appending(path: "\(Self.ytDlpName).\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: supportFolder, withIntermediateDirectories: true)
            try manager.copyItem(at: bundledYtDlp, to: temporary)
            _ = try manager.replaceItemAt(copiedYtDlp, withItemAt: temporary)
        } catch {
            try? manager.removeItem(at: temporary)
        }
    }

    private func version(of program: URL) async -> String? {
        let ending = await HelperProcess(path: program.path, arguments: ["--ignore-config", "--version"]).run()
        guard ending.exitCode == 0 else { return nil }
        let text = String(decoding: ending.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
