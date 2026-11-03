import Foundation
import SwiftpolisBridge
import SwiftpolisDomain
import SwiftpolisEngines

/// What the Add Link and Properties windows edit: every option, as text and switches.
public struct DownloadDraft: Equatable, Sendable {
    public var link = ""
    public var changesName = false
    public var customName = ""
    public var folder: String
    public var connections: Int
    public var category = CategoryKind.singleDownloadsName

    public var usesStartTime = false
    public var startTime = ClockTime(hour: 0, minute: 0)!
    public var usesEndTime = false
    public var endTime = ClockTime(hour: 0, minute: 0)!

    public var usesProxy = false
    public var proxyKind = ProxySettings.Kind.http
    public var proxyHost = ""
    public var proxyPort = 0
    public var proxyUser = ""
    public var proxyPassword = ""

    public var usesLogin = false
    public var loginUser = ""
    public var loginPassword = ""

    public var referer = ""
    public var userAgent = ""
    public var headers = ""
    public var cookieFilePath = ""
    /// A browser's cookies. They travel with the Download but aren't shown for editing.
    public var cookieHeader: String?
    /// Video Finder sets this. Otherwise it follows from the name.
    public var engine = DownloadEngineKind.http

    /// A blank draft, for adding a Download.
    public init(preferences: Preferences) {
        folder = preferences.downloadFolder
        connections = preferences.connections
    }

    /// A draft of a link from a browser.
    public init(preferences: Preferences, browserLink link: BrowserLink) {
        self.init(preferences: preferences)
        self.link = link.url
        if let name = link.fileName {
            changesName = true
            customName = name
        }
        userAgent = link.userAgent ?? ""
        referer = link.referrer ?? ""
        headers = link.headers ?? ""
        cookieFilePath = link.cookieFilePath ?? ""
        cookieHeader = link.cookies
    }

    /// A draft of an existing Download, for its Properties window.
    public init(editing download: DownloadSummary, secrets: DownloadSecrets) {
        let request = download.request
        link = request.link
        changesName = request.customFileName != nil
        customName = request.customFileName ?? ""
        folder = request.folder
        connections = request.connections
        category = download.category
        if let time = request.startTime {
            usesStartTime = true
            startTime = time
        }
        if let time = request.endTime {
            usesEndTime = true
            endTime = time
        }
        if let proxy = request.proxy {
            usesProxy = true
            proxyKind = proxy.kind
            proxyHost = proxy.host
            proxyPort = proxy.port
            proxyUser = proxy.user ?? ""
        }
        proxyPassword = secrets.proxyPassword ?? ""
        usesLogin = request.httpUser != nil
        loginUser = request.httpUser ?? ""
        loginPassword = secrets.httpPassword ?? ""
        cookieHeader = secrets.cookieHeader
        referer = request.referer ?? ""
        userAgent = request.userAgent ?? ""
        headers = request.headers ?? ""
        cookieFilePath = request.cookieFilePath ?? ""
        engine = request.engine
    }

    /// A Queue's Downloads run on the Queue's times, not their own.
    public var canHaveOwnTimes: Bool {
        CategoryKind(categoryName: category) == .singleDownloads
    }

    public var hasLink: Bool {
        !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Download's options. Empty fields mean "not set", and switched-off sections don't count,
    /// whatever their fields still hold.
    public var request: DownloadRequest {
        var request = DownloadRequest(
            link: link.trimmingCharacters(in: .whitespacesAndNewlines),
            folder: folder,
            connections: connections
        )
        request.customFileName = changesName ? Self.nonEmpty(customName) : nil
        if canHaveOwnTimes {
            request.startTime = usesStartTime ? startTime : nil
            request.endTime = usesEndTime ? endTime : nil
        }
        if usesProxy, let host = Self.nonEmpty(proxyHost), proxyPort > 0 {
            request.proxy = ProxySettings(kind: proxyKind, host: host, port: proxyPort, user: Self.nonEmpty(proxyUser))
        }
        request.httpUser = usesLogin ? Self.nonEmpty(loginUser) : nil
        request.referer = Self.nonEmpty(referer)
        request.userAgent = Self.nonEmpty(userAgent)
        request.headers = Self.nonEmpty(headers)
        request.cookieFilePath = Self.nonEmpty(cookieFilePath)
        request.engine = engine == .ytDlp ? .ytDlp : DownloadEngineKind(customFileName: request.customFileName)
        return request
    }

    public var secrets: DownloadSecrets {
        DownloadSecrets(
            proxyPassword: usesProxy ? Self.nonEmpty(proxyPassword) : nil,
            httpPassword: usesLogin ? Self.nonEmpty(loginPassword) : nil,
            cookieHeader: cookieHeader
        )
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What the batch window edits: links to pick from, and options they all share.
public struct BatchDraft: Equatable, Sendable {
    public struct Item: Equatable, Identifiable, Sendable {
        public let id: Int
        public let link: BrowserLink
        public var isSelected = true
        /// Filled in by the Spider. Until then the name is unknown, and the server decides.
        public var name: String?

        /// What the list shows: the name if known, otherwise the one the link itself gives the file.
        public var shownName: String { name ?? Spider.fileName(inLink: link.url) }
    }

    public struct Addition: Sendable {
        public let request: DownloadRequest
        public let secrets: DownloadSecrets
    }

    public var items: [Item]
    /// The link in here is ignored, as each item has its own.
    public var options: DownloadDraft

    public init(preferences: Preferences, links: [BrowserLink]) {
        items = links.enumerated().map { Item(id: $0.offset, link: $0.element, name: $0.element.fileName) }
        options = DownloadDraft(preferences: preferences)
    }

    public var hasSelection: Bool { items.contains(where: \.isSelected) }

    public mutating func setAllSelected(_ isSelected: Bool) {
        for index in items.indices { items[index].isSelected = isSelected }
    }

    /// What to add. The list shows the newest first, so adding from the bottom up leaves the list in
    /// the order shown here, and a Queue runs from the top.
    public var selectedInAddingOrder: [Addition] {
        items.reversed().filter(\.isSelected).map { item in
            var draft = DownloadDraft(preferences: Preferences(), browserLink: item.link)
            draft.changesName = item.name != nil
            draft.customName = item.name ?? ""
            draft.folder = options.folder
            draft.connections = options.connections
            draft.usesProxy = options.usesProxy
            draft.proxyKind = options.proxyKind
            draft.proxyHost = options.proxyHost
            draft.proxyPort = options.proxyPort
            draft.proxyUser = options.proxyUser
            draft.proxyPassword = options.proxyPassword
            draft.usesLogin = options.usesLogin
            draft.loginUser = options.loginUser
            draft.loginPassword = options.loginPassword
            return Addition(request: draft.request, secrets: draft.secrets)
        }
    }
}

/// Where a Browser request goes, from Persepolis's `checkPluginCall`.
public enum BrowserRequestRoute: Equatable, Sendable {
    case addLink(BrowserLink)
    case startNow(BrowserLink)
    case batch([BrowserLink])

    public init?(links: [BrowserLink], startsImmediately: Bool) {
        switch links.count {
        case 0: return nil
        case 1: self = startsImmediately ? .startNow(links[0]) : .addLink(links[0])
        default: self = .batch(links)
        }
    }
}

public enum QueueNaming {
    public static func message(for error: Error, name: String) -> String {
        switch error as? QueueNameError {
        case .alreadyExists: "\"\(name)\" already exists!"
        case .empty: "Enter a queue name."
        case nil: error.localizedDescription
        }
    }
}

public enum LinkText {
    /// The links in a piece of text, one per line as in a text file of links. A single-line field can
    /// turn a list's line breaks into spaces, so a space before another link separates them too.
    public static func links(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .flatMap { $0.split(separator: /\s+(?=https?:\/\/)/) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(looksLikeLink)
    }

    /// Persepolis's test for whether copied text is a link. In practice this means it starts with
    /// `http://` or `https://`, or something the same shape.
    public static func looksLikeLink(_ text: String) -> Bool {
        let characters = Array(text)
        func contains(_ needle: String, from start: Int, to end: Int) -> Bool {
            guard characters.count > start else { return false }
            return String(characters[start..<min(end, characters.count)]).contains(needle)
        }
        return contains("tp:/", from: 2, to: 6) || contains("tps:/", from: 2, to: 7)
    }
}

/// The files that let Chrome-family browsers and Firefox start the helper.
public enum NativeHostManifests {
    private static let hostName = "com.persepolis.pdmchromewrapper"
    private static let chromeFamily = [
        "Google/Chrome", "Chromium", "Vivaldi", "Opera", "BraveSoftware/Brave-Browser",
    ]
    private static let firefox = "Mozilla"

    /// Writes a manifest for each browser that's installed. Unlike Persepolis, this leaves no folders
    /// behind for browsers the user doesn't have.
    public static func install(helperPath: String, home: URL) {
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        for browser in chromeFamily {
            write(
                ["allowed_origins": ["chrome-extension://legimlagjjoghkoedakdjhocbeomojao/"]],
                helperPath: helperPath,
                browser: browser,
                support: support
            )
        }
        write(
            ["allowed_extensions": [
                "com.persepolis.pdmchromewrapper@persepolisdm.github.io",
                "com.persepolis.pdmchromewrapper.offline@persepolisdm.github.io",
            ]],
            helperPath: helperPath,
            browser: firefox,
            support: support
        )
    }

    private static func write(_ allowed: [String: [String]], helperPath: String, browser: String, support: URL) {
        let manager = FileManager.default
        let browserFolder = support.appending(path: browser, directoryHint: .isDirectory)
        guard manager.fileExists(atPath: browserFolder.path) else { return }

        var manifest: [String: Any] = [
            "name": hostName,
            "type": "stdio",
            "path": helperPath,
            "description": "Integrate Swiftpolis with \(browser) using WebExtensions",
        ]
        manifest.merge(allowed) { _, new in new }

        let folder = browserFolder.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
              (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return }
        try? data.write(to: folder.appending(path: hostName + ".json"), options: .atomic)
    }
}
