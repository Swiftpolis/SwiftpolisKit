#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// A folder of Browser requests, shared by the browsers' helpers and the app.
///
/// Each request is one file, so nothing needs the app to be running, and writers never get in each
/// other's way. See docs/adr/0007-browser-requests-via-shared-inbox.md.
public struct BrowserInbox: Sendable {
    #if os(iOS)
    public static let appGroup = "group.com.amirabravesh.Swiftpolis"

    /// A shared link waits for the person to open the app, which may not be today.
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    #else
    public static let appGroup = "Y4JD236954.com.amirabravesh.Swiftpolis"
    private static let wakeURL = URL(string: "swiftpolis://inbox")!

    /// A request older than this is thrown away, so a forgotten link can't pop up days later.
    private static let maximumAge: TimeInterval = 24 * 60 * 60
    #endif

    private let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The inbox every browser shares, or `nil` if this program can't reach the App Group.
    public static var shared: BrowserInbox? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { BrowserInbox(folder: $0.appending(path: "Inbox", directoryHint: .isDirectory)) }
    }

    #if canImport(AppKit)
    /// Launches the app, or tells it there's something new. The link carries no data, so a web page
    /// opening it can achieve nothing but an empty check of the inbox.
    ///
    /// This waits for the request to go through, because the helper exits straight afterwards, and
    /// an open still in progress would die with it.
    public static func wakeApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let finished = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open(wakeURL, configuration: configuration) { _, _ in
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 5)
    }
    #endif

    #if os(iOS)
    /// What the app listens for, to see links shared while it's already on screen beside another app.
    public static let wakeNotification = "com.amirabravesh.Swiftpolis.inbox"

    /// The one notification saying links are waiting. A newer one replaces it, and the app removes it.
    public static let waitingNotificationID = "shared-links"

    /// Tells the app there's something new, if it's running. An extension can't launch its app on iOS.
    public static func wakeApp() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(wakeNotification as CFString),
            nil,
            nil,
            true
        )
    }
    #endif

    public func write(_ links: [BrowserLink], at date: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = String(format: "%016lld-%@", Int64(date.timeIntervalSince1970 * 1_000), UUID().uuidString)

        // Written under another name first, so a reader never sees half a request. These can hold
        // cookies, so only this user can read them.
        let temporary = folder.appending(path: name + ".partial")
        guard manager.createFile(
            atPath: temporary.path,
            contents: try JSONEncoder().encode(links),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try manager.moveItem(at: temporary, to: folder.appending(path: name + ".json"))
    }

    /// Takes every waiting request, oldest first. Anything taken is gone from the inbox.
    public func drain(at date: Date = Date()) -> [[BrowserLink]] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        var requests: [[BrowserLink]] = []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? manager.removeItem(at: file) }
            guard let written = writtenDate(of: file),
                  date.timeIntervalSince(written) <= Self.maximumAge,
                  let data = try? Data(contentsOf: file),
                  let links = try? JSONDecoder().decode([BrowserLink].self, from: data)
            else { continue }
            requests.append(links)
        }
        return requests
    }

    private func writtenDate(of file: URL) -> Date? {
        let prefix = file.lastPathComponent.prefix { $0 != "-" }
        return Int64(prefix).map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }
}
