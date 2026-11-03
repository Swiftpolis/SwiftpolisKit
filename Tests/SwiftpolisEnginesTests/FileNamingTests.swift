import Testing
@testable import SwiftpolisEngines

@Suite("File naming")
struct FileNamingTests {
    @Test("the priority is custom name, then Content-Disposition, then the link")
    func priority() {
        let link = "https://example.com/from-link.zip"
        let header = "attachment; filename=from-header.zip"
        #expect(FileNaming.resolve(custom: "mine.zip", contentDisposition: header, link: link) == "mine.zip")
        #expect(FileNaming.resolve(custom: nil, contentDisposition: header, link: link) == "from-header.zip")
        #expect(FileNaming.resolve(custom: nil, contentDisposition: nil, link: link) == "from-link.zip")
    }

    @Test("Content-Disposition forms", arguments: [
        ("attachment; filename=plain.zip", "plain.zip"),
        ("attachment; filename=\"report.pdf\"", "report.pdf"),           // Fixes D7.
        ("attachment; filename=\"two words.pdf\"; size=5", "two words.pdf"),
        ("attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf", "résumé.pdf"), // Fixes D7.
        ("attachment; filename=\"fallback.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf", "résumé.pdf"),
        ("ATTACHMENT; FILENAME=upper.zip", "upper.zip"),
    ])
    func dispositions(header: String, name: String) {
        #expect(FileNaming.resolve(custom: nil, contentDisposition: header, link: "https://x/y") == name)
    }

    @Test("a header with no name falls back to the link")
    func headerWithoutName() {
        #expect(FileNaming.resolve(custom: nil, contentDisposition: "inline", link: "https://x/y.zip") == "y.zip")
    }

    @Test("link names are percent-decoded and lose their query")
    func linkNames() {
        #expect(FileNaming.resolve(custom: nil, contentDisposition: nil, link: "https://x/a%20b.zip?t=1#f") == "a b.zip")
    }

    @Test("a link with no file name still gives a usable name")
    func emptyLinkName() {
        #expect(FileNaming.resolve(custom: nil, contentDisposition: nil, link: "https://example.com/") == "download")
    }

    @Test("a server can't choose a path outside the download folder", arguments: [
        ("attachment; filename=\"../../evil.sh\"", "evil.sh"),
        ("attachment; filename=\"/etc/passwd\"", "passwd"),
        ("attachment; filename*=UTF-8''..%2F..%2Fevil.sh", "evil.sh"),
        ("attachment; filename=\"..\"", "download"),
    ])
    func noTraversal(header: String, name: String) {
        #expect(FileNaming.resolve(custom: nil, contentDisposition: header, link: "https://x/") == name)
    }

    // Results recorded from real Persepolis.
    @Test("unique names match what Persepolis produced", arguments: [
        (["long.bin"], "long.bin", "long_1.bin"),
        (["long.bin", "long_1.bin"], "long.bin", "long_2.bin"),
        (["x_1.bin"], "x_1.bin", "x_2.bin"),
        (["long_9.bin"], "long_9.bin", "long_10.bin"),
        (["noext"], "noext", "noext_1"),
        ([], "free.bin", "free.bin"),
    ])
    func uniqueNames(existing: [String], name: String, expected: String) {
        #expect(FileNaming.unique(name, exists: existing.contains) == expected)
    }

    @Test("a one-character name doesn't crash on a collision (fixes D16)")
    func shortNames() {
        #expect(FileNaming.unique("a.zip", exists: ["a.zip"].contains) == "a_1.zip")
        #expect(FileNaming.unique("x", exists: ["x"].contains) == "x_1")
    }

    @Test("a long name is shortened to leave room for the control-file suffix, keeping its extension")
    func longNames() {
        let name = String(repeating: "é", count: 200) + ".zip"
        let short = FileNaming.fittingFileSystem(name)
        #expect(short.hasSuffix(".zip"))
        #expect((short + ".persepolis").utf8.count <= 255)
        #expect(FileNaming.fittingFileSystem("short.zip") == "short.zip")
    }
}

@Suite("Subfolders")
struct SubfolderTests {
    // Observed: song.MP3, clip.mkv, book.pdf, data.zip, old.Z and noext.
    @Test("files go where Persepolis put them", arguments: [
        ("song.MP3", "Audios"),
        ("clip.mkv", "Videos"),
        ("book.pdf", "Documents"),
        ("data.zip", "Compressed"),
        ("old.Z", "Compressed"),
        ("noext", "Others"),
        ("thing.xyz", "Others"),
    ])
    func observed(name: String, folder: String) {
        #expect(FileClassifier.subfolder(for: name) == folder)
    }

    @Test("a file named videoplayback is a video")
    func videoPlayback() {
        #expect(FileClassifier.subfolder(for: "videoplayback") == "Videos")
    }

    @Test("a query left in the name is ignored")
    func queryInName() {
        #expect(FileClassifier.subfolder(for: "a.mp4?token=1") == "Videos")
    }

    @Test("pub and mobi are documents (fixes D14)", arguments: ["book.pub", "book.mobi"])
    func documents(name: String) {
        #expect(FileClassifier.subfolder(for: name) == "Documents")
    }

    @Test("f is an archive (fixes D15)")
    func fortranArchive() {
        #expect(FileClassifier.subfolder(for: "old.F") == "Compressed")
    }
}

@Suite("Request text")
struct RequestTextTests {
    @Test("header text becomes pairs, skipping a request line and blanks")
    func headers() {
        let text = "GET /x HTTP/1.1\nX-One: 1\nX-Two: two words\n\nX-Url: http://a:80/"
        #expect(RequestText.headers(from: text) == [
            "X-One": "1", "X-Two": "two words", "X-Url": "http://a:80/",
        ])
    }

    @Test("a cookie file keeps 7-field lines, including HttpOnly ones (fixes D24)")
    func cookies() {
        let text = """
        # Netscape HTTP Cookie File
        example.com\tFALSE\t/\tFALSE\t0\tvisible\tyes
        #HttpOnly_example.com\tFALSE\t/\tFALSE\t0\thidden\tyes
        too few fields
        """
        let cookies = RequestText.cookies(from: text)
        #expect(cookies.map(\.name) == ["visible", "hidden"])
        #expect(cookies[1].domain == "example.com")
        #expect(cookies[1].path == "/")
    }
}

@Suite("Retry and speed rules")
struct RetryAndSpeedRuleTests {
    @Test("the first retry is immediate, then the wait doubles from the retry-wait setting")
    func backoff() {
        #expect(RetryPolicy.delay(afterFailure: 1, retryWait: 5) == 0)
        #expect(RetryPolicy.delay(afterFailure: 2, retryWait: 5) == 10)
        #expect(RetryPolicy.delay(afterFailure: 3, retryWait: 5) == 20)
        #expect(RetryPolicy.delay(afterFailure: 4, retryWait: 5) == 40)
    }

    @Test("the wait never exceeds two minutes")
    func backoffCap() {
        #expect(RetryPolicy.delay(afterFailure: 10, retryWait: 5) == 120)
    }

    @Test("only these statuses are retried on the spot", arguments: [
        (429, true), (500, true), (502, true), (503, true), (504, true),
        (404, false), (403, false), (501, false),
    ])
    func retryableStatuses(status: Int, retryable: Bool) {
        #expect(RetryPolicy.isRetryable(status: status) == retryable)
    }

    @Test("the Speed dial delay uses Persepolis's formula", arguments: [
        (10, 64, 0.0),
        (0, 64, 3.2),
        (5, 16, 0.4),
        (9, 4, 0.02),
    ])
    func speedDial(dial: Int, connections: Int, seconds: Double) {
        let delay = SpeedDial.delayPerChunk(dial: dial, connections: connections)
        #expect(abs(delay - seconds) < 0.000_001)
    }
}
