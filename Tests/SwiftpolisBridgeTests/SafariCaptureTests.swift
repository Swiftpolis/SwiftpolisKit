import Foundation
import JavaScriptCore
import Testing

/// Runs the Safari extension's real capture script, because that's the code Safari will run.
@Suite("Safari click capture")
struct SafariCaptureTests {
    private static let scriptURL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "SafariExtension/Resources/contentScripts/capture.js")

    private func shouldCapture(
        _ url: String,
        enabled: Bool = true,
        keywords: String = "",
        hasDownloadAttribute: Bool = false
    ) throws -> Bool {
        let context = try #require(JSContext())
        let script = try String(contentsOf: Self.scriptURL, encoding: .utf8)
        context.evaluateScript(script)
        let function = try #require(context.objectForKeyedSubscript("swiftpolisShouldCapture"))
        let result = function.call(withArguments: [
            url,
            ["enabled": enabled, "keywords": keywords, "hasDownloadAttribute": hasDownloadAttribute],
        ])
        #expect(context.exception == nil)
        return try #require(result).toBool()
    }

    @Test("links to files are caught", arguments: [
        "https://example.com/a.zip",
        "https://example.com/movie.MKV",
        "https://example.com/song.mp3",
        "https://example.com/installer.dmg",
        "http://example.com/a.rar",
        "https://example.com/dir/a.tar.gz",
        "https://example.com/a.zip?token=1#part",
        "https://example.com/my%20file.iso",
    ])
    func files(url: String) throws {
        #expect(try shouldCapture(url))
    }

    @Test("ordinary links are left alone", arguments: [
        "https://example.com/",
        "https://example.com/page",
        "https://example.com/page.html",
        "https://example.com/page.php?file=a.zip",
        "https://example.com/doc.pdf",
        "https://example.com/picture.png",
        "https://example.zip/",
        "mailto:someone@example.com",
        "javascript:void(0)",
        "#section",
        "",
    ])
    func ordinaryLinks(url: String) throws {
        #expect(try !shouldCapture(url))
    }

    @Test("a link marked as a download is caught, whatever its name")
    func downloadAttribute() throws {
        #expect(try shouldCapture("https://example.com/get?id=5", hasDownloadAttribute: true))
    }

    @Test("blob and data links can't be fetched by a download manager, even if marked")
    func blobLinks() throws {
        #expect(try !shouldCapture("blob:https://example.com/123", hasDownloadAttribute: true))
        #expect(try !shouldCapture("data:text/plain,hello", hasDownloadAttribute: true))
    }

    @Test("switched off, nothing is caught")
    func disabled() throws {
        #expect(try !shouldCapture("https://example.com/a.zip", enabled: false))
    }

    @Test("excluded keywords win", arguments: [
        ".zip", "example.com", ".mp3, .zip", ".mp3 .zip",
    ])
    func keywords(keywords: String) throws {
        #expect(try !shouldCapture("https://example.com/a.zip", keywords: keywords))
    }

    @Test("other keywords don't matter")
    func otherKeywords() throws {
        #expect(try shouldCapture("https://example.com/a.zip", keywords: ".mp3, other.com"))
    }
}
