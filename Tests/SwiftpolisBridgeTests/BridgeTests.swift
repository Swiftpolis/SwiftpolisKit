import Foundation
import Testing
import SwiftpolisBridge

@Suite("Browser message")
struct BrowserMessageTests {
    private func links(_ json: String) -> [BrowserLink] {
        BrowserMessage.links(from: Data(json.utf8))
    }

    // The exact shape real Persepolis was sent in docs/persepolis-observed.md.
    @Test("reads what the extension sends, including its cookies (fixes D8)")
    func extensionMessage() {
        let found = links("""
        {"url_links": [{"url": "https://example.com/file.zip", "cookies": "session=abc123; theme=dark",
         "useragent": "Mozilla/5.0 Test", "referrer": "https://example.com/page", "postdata": ""}],
         "version": "4.0.0"}
        """)

        #expect(found == [BrowserLink(
            url: "https://example.com/file.zip",
            cookies: "session=abc123; theme=dark",
            userAgent: "Mozilla/5.0 Test",
            referrer: "https://example.com/page"
        )])
    }

    @Test("several links keep their order")
    func several() {
        let found = links(#"{"url_links": [{"url": "https://a/1"}, {"url": "https://a/2"}]}"#)
        #expect(found.map(\.url) == ["https://a/1", "https://a/2"])
    }

    @Test("empty values aren't set")
    func emptyValues() {
        let found = links(#"{"url_links": [{"url": "https://a", "cookies": "", "referrer": "", "useragent": ""}]}"#)
        #expect(found == [BrowserLink(url: "https://a")])
    }

    @Test("a suggested file name loses any path, as in Persepolis")
    func fileName() {
        let found = links(#"{"url_links": [{"url": "https://a", "filename": "/some/where/b.zip"}]}"#)
        #expect(found.first?.fileName == "b.zip")
    }

    @Test("the other optional fields carry through")
    func otherFields() {
        let found = links(#"{"url_links": [{"url": "https://a", "header": "X: 1", "load_cookies": "/c.txt"}]}"#)
        #expect(found.first?.headers == "X: 1")
        #expect(found.first?.cookieFilePath == "/c.txt")
    }

    @Test("a link with no URL is skipped")
    func missingURL() {
        #expect(links(#"{"url_links": [{"referrer": "x"}, {"url": "https://a"}]}"#).map(\.url) == ["https://a"])
    }

    @Test("a message with no links, like the extension's first hello, finds nothing", arguments: [
        #"{"version": "4.0.0"}"#, "not json", "[]",
    ])
    func noLinks(json: String) {
        #expect(links(json).isEmpty)
    }
}

@Suite("Native messaging")
struct NativeMessagingTests {
    @Test("a frame is a 4-byte length, then the data")
    func frame() {
        let framed = NativeMessaging.frame(Data("abc".utf8))
        #expect(framed == Data([3, 0, 0, 0]) + Data("abc".utf8))
    }

    @Test("the reply matches what Persepolis sends")
    func reply() throws {
        let json = try JSONSerialization.jsonObject(with: NativeMessaging.reply) as? [String: Any]
        #expect(json?["enable"] as? Bool == true)
        #expect(json?["version"] as? String == "1.85")
    }

    private func reading(_ bytes: Data) throws -> Data? {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()
        return NativeMessaging.readFrame(from: pipe.fileHandleForReading)
    }

    @Test("a frame reads back")
    func readsFrame() throws {
        #expect(try reading(NativeMessaging.frame(Data("hello".utf8))) == Data("hello".utf8))
    }

    @Test("nothing to read gives nothing", arguments: [Data(), Data([5, 0]), Data([5, 0, 0, 0, 1])])
    func truncated(bytes: Data) throws {
        #expect(try reading(bytes) == nil)
    }

    @Test("an absurd length is refused, not allocated")
    func hugeLength() throws {
        #expect(try reading(Data([0xFF, 0xFF, 0xFF, 0x7F])) == nil)
    }
}

@Suite("Browser inbox")
struct BrowserInboxTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeInbox() throws -> (BrowserInbox, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (BrowserInbox(folder: folder), folder)
    }

    private func files(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    @Test("a request written is read once, and then gone")
    func roundTrip() throws {
        let (inbox, folder) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let links = [BrowserLink(url: "https://a", cookies: "c=1"), BrowserLink(url: "https://b")]

        try inbox.write(links, at: now)

        #expect(inbox.drain(at: now) == [links])
        #expect(inbox.drain(at: now).isEmpty)
        #expect(files(in: folder).isEmpty)
    }

    @Test("requests come back in the order they were written, and stay separate")
    func order() throws {
        let (inbox, folder) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }

        try inbox.write([BrowserLink(url: "https://1")], at: now)
        try inbox.write([BrowserLink(url: "https://2")], at: now.addingTimeInterval(1))
        try inbox.write([BrowserLink(url: "https://3")], at: now.addingTimeInterval(2))

        let drained = inbox.drain(at: now.addingTimeInterval(3))
        #expect(drained.map { $0.map(\.url) } == [["https://1"], ["https://2"], ["https://3"]])
    }

    @Test("an empty folder, or none at all, is simply empty")
    func nothing() throws {
        let (inbox, _) = try makeInbox()
        #expect(inbox.drain(at: now).isEmpty)
    }

    @Test("a request holding cookies is readable only by this user")
    func permissions() throws {
        let (inbox, folder) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }

        try inbox.write([BrowserLink(url: "https://a", cookies: "c=1")], at: now)

        let file = try #require(files(in: folder).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test("an old request is thrown away unread, so a forgotten link can't pop up days later")
    func expiry() throws {
        let (inbox, folder) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }

        try inbox.write([BrowserLink(url: "https://old")], at: now)
        try inbox.write([BrowserLink(url: "https://new")], at: now.addingTimeInterval(23 * 3_600))

        let drained = inbox.drain(at: now.addingTimeInterval(25 * 3_600))

        #expect(drained.map { $0.map(\.url) } == [["https://new"]])
        #expect(files(in: folder).isEmpty)
    }

    @Test("a damaged file is removed, and doesn't block the rest")
    func damaged() throws {
        let (inbox, folder) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        try inbox.write([BrowserLink(url: "https://good")], at: now)
        try Data("nonsense".utf8).write(to: folder.appending(path: "bad.json"))

        #expect(inbox.drain(at: now).map { $0.map(\.url) } == [["https://good"]])
        #expect(files(in: folder).isEmpty)
    }
}
