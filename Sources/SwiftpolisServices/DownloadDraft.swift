import Foundation
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

    /// A blank draft, for adding a Download.
    public init(preferences: Preferences) {
        folder = preferences.downloadFolder
        connections = preferences.connections
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
        referer = request.referer ?? ""
        userAgent = request.userAgent ?? ""
        headers = request.headers ?? ""
        cookieFilePath = request.cookieFilePath ?? ""
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
        if usesProxy, let host = Self.nonEmpty(proxyHost), proxyPort > 0 {
            request.proxy = ProxySettings(kind: proxyKind, host: host, port: proxyPort, user: Self.nonEmpty(proxyUser))
        }
        request.httpUser = usesLogin ? Self.nonEmpty(loginUser) : nil
        request.referer = Self.nonEmpty(referer)
        request.userAgent = Self.nonEmpty(userAgent)
        request.headers = Self.nonEmpty(headers)
        request.cookieFilePath = Self.nonEmpty(cookieFilePath)
        return request
    }

    public var secrets: DownloadSecrets {
        DownloadSecrets(
            proxyPassword: usesProxy ? Self.nonEmpty(proxyPassword) : nil,
            httpPassword: usesLogin ? Self.nonEmpty(loginPassword) : nil
        )
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum LinkText {
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
