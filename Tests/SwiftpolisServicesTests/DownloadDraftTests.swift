import Foundation
import Testing
import SwiftpolisDomain
import SwiftpolisEngines
import SwiftpolisServices

@Suite("Download draft")
struct DownloadDraftTests {
    private func blank() -> DownloadDraft {
        var preferences = Preferences()
        preferences.downloadFolder = "/d"
        preferences.connections = 12
        return DownloadDraft(preferences: preferences)
    }

    @Test("a new draft takes the folder and Connections from Preferences, and is a Single Download")
    func defaults() {
        let draft = blank()
        #expect(draft.folder == "/d")
        #expect(draft.connections == 12)
        #expect(draft.category == "Single Downloads")
        #expect(!draft.hasLink)
    }

    @Test("empty fields aren't set, and the link is trimmed")
    func emptyFields() {
        var draft = blank()
        draft.link = "  https://a/b.zip\n"
        let request = draft.request

        #expect(draft.hasLink)
        #expect(request.link == "https://a/b.zip")
        #expect(request.customFileName == nil)
        #expect(request.proxy == nil)
        #expect(request.httpUser == nil)
        #expect(request.referer == nil)
        #expect(request.userAgent == nil)
        #expect(request.headers == nil)
        #expect(request.cookieFilePath == nil)
    }

    @Test("switched-off sections don't count, whatever their fields hold")
    func switchedOff() {
        var draft = blank()
        draft.customName = "x"
        draft.proxyHost = "h"
        draft.proxyPort = 80
        draft.proxyPassword = "p"
        draft.loginUser = "u"
        draft.loginPassword = "q"

        #expect(draft.request.customFileName == nil)
        #expect(draft.request.proxy == nil)
        #expect(draft.request.httpUser == nil)
        #expect(draft.secrets.proxyPassword == nil)
        #expect(draft.secrets.httpPassword == nil)
    }

    @Test("switched-on sections carry through")
    func switchedOn() {
        var draft = blank()
        draft.changesName = true
        draft.customName = "x.zip"
        draft.usesProxy = true
        draft.proxyKind = .socks5
        draft.proxyHost = "h"
        draft.proxyPort = 1080
        draft.proxyUser = "pu"
        draft.proxyPassword = "pp"
        draft.usesLogin = true
        draft.loginUser = "lu"
        draft.loginPassword = "lp"

        #expect(draft.request.customFileName == "x.zip")
        #expect(draft.request.proxy == ProxySettings(kind: .socks5, host: "h", port: 1080, user: "pu"))
        #expect(draft.request.httpUser == "lu")
        #expect(draft.secrets.proxyPassword == "pp")
        #expect(draft.secrets.httpPassword == "lp")
    }

    @Test("a proxy without a host or port isn't a proxy", arguments: [("", 80), ("h", 0)])
    func incompleteProxy(host: String, port: Int) {
        var draft = blank()
        draft.usesProxy = true
        draft.proxyHost = host
        draft.proxyPort = port
        #expect(draft.request.proxy == nil)
    }

    @Test("editing a Download and saving unchanged gives back the same options")
    func roundTrip() throws {
        var request = DownloadRequest(link: "https://a", folder: "/f", connections: 3)
        request.customFileName = "n"
        request.proxy = ProxySettings(kind: .http, host: "h", port: 8, user: "u")
        request.httpUser = "l"
        request.referer = "r"
        request.userAgent = "ua"
        request.headers = "X: 1"
        request.cookieFilePath = "/c"
        let secrets = DownloadSecrets(proxyPassword: "pp", httpPassword: "lp")
        let summary = DownloadSummary(
            gid: try #require(GID(rawValue: "1a2b3c4d5e6f7a8b")),
            request: request,
            status: .stopped,
            category: "Movies",
            fileName: "n",
            filePath: nil,
            totalBytes: nil,
            downloadedBytes: 0,
            firstTryDate: Date(timeIntervalSince1970: 0),
            lastTryDate: Date(timeIntervalSince1970: 0)
        )

        let draft = DownloadDraft(editing: summary, secrets: secrets)

        #expect(draft.request == request)
        #expect(draft.secrets.proxyPassword == "pp")
        #expect(draft.secrets.httpPassword == "lp")
        #expect(draft.category == "Movies")
    }
}

@Suite("Link text")
struct LinkTextTests {
    @Test("Persepolis's link test", arguments: [
        ("http://a", true),
        ("https://a", true),
        ("ftp://a", false),
        ("HTTPS://a", false),
        ("just words", false),
        ("", false),
        ("ht", false),
    ])
    func links(text: String, isLink: Bool) {
        #expect(LinkText.looksLikeLink(text) == isLink)
    }
}
