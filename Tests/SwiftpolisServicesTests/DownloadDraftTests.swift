import Foundation
import Testing
import SwiftpolisBridge
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

    @Test("Start and End times count only when switched on")
    func times() {
        var draft = blank()
        draft.startTime = ClockTime(hour: 2, minute: 0)!
        draft.endTime = ClockTime(hour: 6, minute: 0)!
        #expect(draft.request.startTime == nil)
        #expect(draft.request.endTime == nil)

        draft.usesStartTime = true
        draft.usesEndTime = true
        #expect(draft.request.startTime == ClockTime(hour: 2, minute: 0))
        #expect(draft.request.endTime == ClockTime(hour: 6, minute: 0))
    }

    @Test("a Queue's Download has no times of its own, as the Queue's apply")
    func timesInQueue() {
        var draft = blank()
        draft.usesStartTime = true
        draft.usesEndTime = true
        draft.category = "Scheduled Downloads"
        #expect(!draft.canHaveOwnTimes)
        #expect(draft.request.startTime == nil)
        #expect(draft.request.endTime == nil)
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

@Suite("Draft from a browser")
struct BrowserDraftTests {
    @Test("a browser's link fills in the options, and its cookies go with the secrets")
    func browserLink() {
        var preferences = Preferences()
        preferences.downloadFolder = "/d"
        let link = BrowserLink(
            url: "https://a/b.zip",
            cookies: "c=1",
            userAgent: "UA",
            referrer: "https://a/",
            fileName: "name.zip",
            headers: "X: 1",
            cookieFilePath: "/c.txt"
        )

        let draft = DownloadDraft(preferences: preferences, browserLink: link)

        #expect(draft.request.link == "https://a/b.zip")
        #expect(draft.request.customFileName == "name.zip")
        #expect(draft.request.userAgent == "UA")
        #expect(draft.request.referer == "https://a/")
        #expect(draft.request.headers == "X: 1")
        #expect(draft.request.cookieFilePath == "/c.txt")
        #expect(draft.request.folder == "/d")
        #expect(draft.secrets.cookieHeader == "c=1")
    }
}

@Suite("Browser request routing")
struct BrowserRequestRouterTests {
    private let one = [BrowserLink(url: "https://a")]
    private let two = [BrowserLink(url: "https://a"), BrowserLink(url: "https://b")]

    @Test("one link opens Add Link")
    func oneLink() {
        #expect(BrowserRequestRoute(links: one, startsImmediately: false) == .addLink(one[0]))
    }

    @Test("one link starts straight away if Preferences say so")
    func immediately() {
        #expect(BrowserRequestRoute(links: one, startsImmediately: true) == .startNow(one[0]))
    }

    @Test("several links open the batch window, even with immediate start on")
    func several() {
        #expect(BrowserRequestRoute(links: two, startsImmediately: true) == .batch(two))
    }

    @Test("no links does nothing")
    func none() {
        #expect(BrowserRequestRoute(links: [], startsImmediately: false) == nil)
    }
}

@Suite("Batch draft")
struct BatchDraftTests {
    private func draft(_ names: String...) -> BatchDraft {
        var preferences = Preferences()
        preferences.downloadFolder = "/d"
        preferences.connections = 7
        return BatchDraft(preferences: preferences, links: names.map { BrowserLink(url: "https://x/\($0)") })
    }

    @Test("every link starts selected, in order, with Preferences' options")
    func starts() {
        let batch = draft("a", "b")
        #expect(batch.items.map(\.isSelected) == [true, true])
        #expect(batch.items.map(\.link.url) == ["https://x/a", "https://x/b"])
        #expect(batch.options.folder == "/d")
        #expect(batch.options.connections == 7)
    }

    @Test("select all and deselect all")
    func selection() {
        var batch = draft("a", "b")
        batch.setAllSelected(false)
        #expect(!batch.hasSelection)
        batch.setAllSelected(true)
        #expect(batch.hasSelection)
    }

    @Test("Downloads are added last-first, so the list ends up in the order shown, as in Persepolis")
    func addOrder() {
        var batch = draft("a", "b", "c")
        batch.items[1].isSelected = false

        #expect(batch.selectedInAddingOrder.map(\.request.link) == ["https://x/c", "https://x/a"])
    }

    @Test("shared options apply to every link, and each keeps its own browser details")
    func sharedOptions() {
        var preferences = Preferences()
        preferences.downloadFolder = "/d"
        let links = [BrowserLink(url: "https://a", cookies: "c=1", userAgent: "UA", referrer: "https://r/")]
        var batch = BatchDraft(preferences: preferences, links: links)
        batch.options.folder = "/other"
        batch.options.connections = 2
        batch.options.usesProxy = true
        batch.options.proxyHost = "h"
        batch.options.proxyPort = 8
        batch.options.proxyPassword = "pp"

        let item = batch.selectedInAddingOrder[0]

        #expect(item.request.folder == "/other")
        #expect(item.request.connections == 2)
        #expect(item.request.proxy?.host == "h")
        #expect(item.request.userAgent == "UA")
        #expect(item.request.referer == "https://r/")
        #expect(item.secrets.proxyPassword == "pp")
        #expect(item.secrets.cookieHeader == "c=1")
    }

    @Test("a name is only set once known, so no file is ever called *** (fixes D30)")
    func names() {
        var batch = draft("a", "b")
        batch.items[0].name = "found.zip"

        let items = batch.selectedInAddingOrder
        #expect(items[1].request.customFileName == "found.zip")
        #expect(items[0].request.customFileName == nil)
    }

    @Test("before the Spider answers, the list shows the name in the link, without adding it as a custom name")
    func shownNames() {
        let link = "https://x/S05/Show.S05E01.mkv?md5=abc&expires=1"
        var batch = BatchDraft(preferences: Preferences(), links: [BrowserLink(url: link)])

        #expect(batch.items[0].shownName == "Show.S05E01.mkv")
        #expect(batch.selectedInAddingOrder[0].request.customFileName == nil)

        batch.items[0].name = "From the server.mkv"
        #expect(batch.items[0].shownName == "From the server.mkv")
    }
}

@Suite("Link text")
struct LinkTextTests {
    @Test("links are picked out of text, one per line, keeping their order")
    func links() {
        let text = "https://a/1\n  http://b/2  \nnot a link\n\nhttps://c/3"
        #expect(LinkText.links(in: text) == ["https://a/1", "http://b/2", "https://c/3"])
    }

    @Test("a season's links, signed and in a row, stay separate and in episode order")
    func seasonList() {
        let first = "https://sn1.example.com/dl4/Show/S05/Show.S05E01.1080p.mkv?md5=DuPYNc-4b9gw&u=1&expires=179"
        let second = "https://sn1.example.com/dl4/Show/S05/Show.S05E02.1080p.mkv?md5=GOQikr_eOlVYBQ&u=1&expires=179"

        for separator in ["\n", "\r\n", " ", "  ", "\t"] {
            #expect(LinkText.links(in: first + separator + second) == [first, second])
        }
    }

    @Test("a space inside a link doesn't split it, and a link inside another's query stays there")
    func oneLink() {
        #expect(LinkText.links(in: "https://a/my file.zip") == ["https://a/my file.zip"])
        #expect(LinkText.links(in: "https://a/go?to=https://b/") == ["https://a/go?to=https://b/"])
    }

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

@Suite("Native host manifests")
struct NativeHostManifestTests {
    private func makeHome(browsers: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for browser in browsers {
            try FileManager.default.createDirectory(
                at: home.appending(path: "Library/Application Support/\(browser)"),
                withIntermediateDirectories: true
            )
        }
        return home
    }

    private func manifest(at path: String, home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appending(
            path: "Library/Application Support/\(path)/NativeMessagingHosts/com.persepolis.pdmchromewrapper.json"
        ))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a Chrome-family browser gets Persepolis's store extension allowed")
    func chrome() throws {
        let home = try makeHome(browsers: ["Google/Chrome"])
        defer { try? FileManager.default.removeItem(at: home) }

        NativeHostManifests.install(helperPath: "/App/helper", home: home)

        let json = try manifest(at: "Google/Chrome", home: home)
        #expect(json["name"] as? String == "com.persepolis.pdmchromewrapper")
        #expect(json["type"] as? String == "stdio")
        #expect(json["path"] as? String == "/App/helper")
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://legimlagjjoghkoedakdjhocbeomojao/"])
        #expect(json["allowed_extensions"] == nil)
    }

    @Test("Firefox gets its own key")
    func firefox() throws {
        let home = try makeHome(browsers: ["Mozilla"])
        defer { try? FileManager.default.removeItem(at: home) }

        NativeHostManifests.install(helperPath: "/App/helper", home: home)

        let json = try manifest(at: "Mozilla", home: home)
        #expect(json["allowed_extensions"] as? [String] == [
            "com.persepolis.pdmchromewrapper@persepolisdm.github.io",
            "com.persepolis.pdmchromewrapper.offline@persepolisdm.github.io",
        ])
        #expect(json["allowed_origins"] == nil)
    }

    @Test("every browser Persepolis supports is covered", arguments: [
        "Google/Chrome", "Chromium", "Vivaldi", "Opera", "BraveSoftware/Brave-Browser", "Mozilla",
    ])
    func everyBrowser(browser: String) throws {
        let home = try makeHome(browsers: [browser])
        defer { try? FileManager.default.removeItem(at: home) }

        NativeHostManifests.install(helperPath: "/App/helper", home: home)

        _ = try manifest(at: browser, home: home)
    }

    @Test("a browser that isn't installed gets nothing")
    func notInstalled() throws {
        let home = try makeHome(browsers: [])
        defer { try? FileManager.default.removeItem(at: home) }

        NativeHostManifests.install(helperPath: "/App/helper", home: home)

        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Library/Application Support/Google").path))
    }
}
