import Foundation
import SwiftpolisDomain
import SwiftpolisEngines

/// The user's preferences. Defaults match Persepolis's, except the download folder's name.
public struct Preferences: Equatable, Sendable {
    public var maxTries = 5
    public var retryWaitSeconds = 5
    public var timeoutSeconds = 10
    public var connections = 64
    public var chunkSizeKiB = 100
    public var queueWaitHours = 0
    public var queueWaitMinutes = 0
    public var verifiesCertificates = true
    #if os(macOS)
    public var downloadFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Downloads/Swiftpolis", directoryHint: .isDirectory).path
    #else
    public var downloadFolder = URL.documentsDirectory.path
    #endif
    public var usesSubfolders = true
    public var playsSounds = true
    public var soundVolumePercent = 100
    public var showsAfterDownloadDialog = true
    public var showsProgressWindow = true
    public var showsMenuBarItem = true
    public var hidesWindowOnClose = true
    public var keepsSystemAwake = false
    public var startsBrowserRequestsImmediately = false
    public var checksClipboard = false
    public var videoFinderMaxLinks = 3
    public var keepsDockIconWithoutWindows = false
    public var checksForUpdates = true
    public var allowsCellularData = true

    public init() {}

    /// Whether the Dock shows the app. Without a menu bar item, the Dock is the only way back to it.
    public func showsDockIcon(hasOpenWindows: Bool) -> Bool {
        hasOpenWindows || keepsDockIconWithoutWindows || !showsMenuBarItem || !hidesWindowOnClose
    }

    public var queueWait: QueueWait {
        QueueWait(hours: queueWaitHours, minutes: queueWaitMinutes)
    }

    public var engineSettings: EngineSettings {
        var settings = EngineSettings()
        settings.maxTries = maxTries
        settings.retryWait = TimeInterval(retryWaitSeconds)
        settings.timeout = TimeInterval(timeoutSeconds)
        settings.chunkSizeKiB = chunkSizeKiB
        settings.verifiesCertificates = verifiesCertificates
        settings.defaultFolder = downloadFolder
        settings.usesSubfolders = usesSubfolders
        settings.allowsCellularData = allowsCellularData
        return settings
    }
}

/// Reads and writes preferences in `UserDefaults`. Settings never saved keep their defaults.
public final class PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var preferences: Preferences {
        get {
            var value = Preferences()
            read(&value.maxTries, "maxTries")
            read(&value.retryWaitSeconds, "retryWaitSeconds")
            read(&value.timeoutSeconds, "timeoutSeconds")
            read(&value.connections, "connections")
            read(&value.chunkSizeKiB, "chunkSizeKiB")
            read(&value.queueWaitHours, "queueWaitHours")
            read(&value.queueWaitMinutes, "queueWaitMinutes")
            read(&value.verifiesCertificates, "verifiesCertificates")
            read(&value.downloadFolder, "downloadFolder")
            read(&value.usesSubfolders, "usesSubfolders")
            read(&value.playsSounds, "playsSounds")
            read(&value.soundVolumePercent, "soundVolumePercent")
            read(&value.showsAfterDownloadDialog, "showsAfterDownloadDialog")
            read(&value.showsProgressWindow, "showsProgressWindow")
            read(&value.showsMenuBarItem, "showsMenuBarItem")
            read(&value.hidesWindowOnClose, "hidesWindowOnClose")
            read(&value.keepsSystemAwake, "keepsSystemAwake")
            read(&value.startsBrowserRequestsImmediately, "startsBrowserRequestsImmediately")
            read(&value.checksClipboard, "checksClipboard")
            read(&value.videoFinderMaxLinks, "videoFinderMaxLinks")
            read(&value.keepsDockIconWithoutWindows, "keepsDockIconWithoutWindows")
            read(&value.checksForUpdates, "checksForUpdates")
            read(&value.allowsCellularData, "allowsCellularData")
            return value
        }
        set {
            defaults.set(newValue.maxTries, forKey: "maxTries")
            defaults.set(newValue.retryWaitSeconds, forKey: "retryWaitSeconds")
            defaults.set(newValue.timeoutSeconds, forKey: "timeoutSeconds")
            defaults.set(newValue.connections, forKey: "connections")
            defaults.set(newValue.chunkSizeKiB, forKey: "chunkSizeKiB")
            defaults.set(newValue.queueWaitHours, forKey: "queueWaitHours")
            defaults.set(newValue.queueWaitMinutes, forKey: "queueWaitMinutes")
            defaults.set(newValue.verifiesCertificates, forKey: "verifiesCertificates")
            defaults.set(newValue.downloadFolder, forKey: "downloadFolder")
            defaults.set(newValue.usesSubfolders, forKey: "usesSubfolders")
            defaults.set(newValue.playsSounds, forKey: "playsSounds")
            defaults.set(newValue.soundVolumePercent, forKey: "soundVolumePercent")
            defaults.set(newValue.showsAfterDownloadDialog, forKey: "showsAfterDownloadDialog")
            defaults.set(newValue.showsProgressWindow, forKey: "showsProgressWindow")
            defaults.set(newValue.showsMenuBarItem, forKey: "showsMenuBarItem")
            defaults.set(newValue.hidesWindowOnClose, forKey: "hidesWindowOnClose")
            defaults.set(newValue.keepsSystemAwake, forKey: "keepsSystemAwake")
            defaults.set(newValue.startsBrowserRequestsImmediately, forKey: "startsBrowserRequestsImmediately")
            defaults.set(newValue.checksClipboard, forKey: "checksClipboard")
            defaults.set(newValue.videoFinderMaxLinks, forKey: "videoFinderMaxLinks")
            defaults.set(newValue.keepsDockIconWithoutWindows, forKey: "keepsDockIconWithoutWindows")
            defaults.set(newValue.checksForUpdates, forKey: "checksForUpdates")
            defaults.set(newValue.allowsCellularData, forKey: "allowsCellularData")
        }
    }

    /// When yt-dlp last looked for an update. This is the app's own note, not a setting.
    public var lastYtDlpUpdateCheck: Date? {
        get { defaults.object(forKey: "lastYtDlpUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastYtDlpUpdateCheck") }
    }

    /// When the app last looked for a newer version of itself.
    public var lastAppUpdateCheck: Date? {
        get { defaults.object(forKey: "lastAppUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastAppUpdateCheck") }
    }

    private func read<Value>(_ value: inout Value, _ key: String) {
        if let stored = defaults.object(forKey: key) as? Value { value = stored }
    }
}
