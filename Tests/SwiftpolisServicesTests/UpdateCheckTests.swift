import Foundation
import SwiftpolisServices
import Testing

@Suite("Versions")
struct AppVersionTests {
    @Test("numbers compare as numbers, and a release tag's v doesn't matter", arguments: [
        ("1.9.0", "1.10.0"),
        ("1.0.0", "v1.0.1"),
        ("1.2", "1.2.1"),
        ("v0.9", "1"),
    ])
    func newer(older: String, newer: String) throws {
        #expect(try #require(AppVersion(older)) < #require(AppVersion(newer)))
    }

    @Test("missing numbers count as zero")
    func equal() throws {
        #expect(try #require(AppVersion("1.0")) == #require(AppVersion("v1.0.0")))
    }

    @Test("other text isn't a version", arguments: ["", "latest", "1.2.x", "1..2", "v"])
    func notAVersion(text: String) {
        #expect(AppVersion(text) == nil)
    }
}

@Suite("Update check")
struct UpdateCheckerTests {
    private func checker(status: Int = 200, body: String) -> UpdateChecker {
        UpdateChecker(repository: "someone/Swiftpolis") { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func release(tag: String, page: String = "https://github.com/someone/Swiftpolis/releases/tag/v2") -> String {
        #"{"tag_name": "\#(tag)", "body": " What changed \n", "html_url": "\#(page)"}"#
    }

    @Test("a newer release is offered, with its notes and page")
    func newer() async throws {
        let result = try await checker(body: release(tag: "v2.0.0")).check(currentVersion: "1.0.0")

        #expect(result == .available(AppRelease(
            version: "v2.0.0",
            notes: "What changed",
            page: URL(string: "https://github.com/someone/Swiftpolis/releases/tag/v2")!
        )))
    }

    @Test("the same or an older release isn't", arguments: ["v1.0.0", "1.0", "v0.9.0"])
    func notNewer(tag: String) async throws {
        let result = try await checker(body: release(tag: tag)).check(currentVersion: "1.0.0")
        #expect(result == .upToDate)
    }

    @Test("nothing published yet isn't a failure")
    func noReleases() async throws {
        let result = try await checker(status: 404, body: "{}").check(currentVersion: "1.0.0")
        #expect(result == .noReleases)
    }

    @Test("a refusal, such as GitHub's rate limit, is reported")
    func refused() async {
        await #expect(throws: UpdateCheckError.refused(status: 403)) {
            try await checker(status: 403, body: "{}").check(currentVersion: "1.0.0")
        }
    }

    @Test("a release page that isn't on GitHub is never offered", arguments: [
        "https://example.com/swiftpolis.dmg",
        "http://github.com/someone/Swiftpolis",
    ])
    func wrongPage(page: String) async {
        await #expect(throws: UpdateCheckError.unreadable) {
            try await checker(body: release(tag: "v2.0.0", page: page)).check(currentVersion: "1.0.0")
        }
    }

    @Test("it asks for this repository's latest release")
    func asksTheRightPlace() async throws {
        let seen = Seen()
        let checker = UpdateChecker(repository: "someone/Swiftpolis") { request in
            await seen.record(request.url)
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        _ = try await checker.check(currentVersion: "1.0.0")

        #expect(await seen.url?.absoluteString == "https://api.github.com/repos/someone/Swiftpolis/releases/latest")
    }

    @Test("the automatic check runs at most once a day")
    func isDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateChecker.isDue(lastCheck: nil, now: now))
        #expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-23 * 3_600), now: now))
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-24 * 3_600), now: now))
    }

    private actor Seen {
        var url: URL?
        func record(_ url: URL?) { self.url = url }
    }
}
