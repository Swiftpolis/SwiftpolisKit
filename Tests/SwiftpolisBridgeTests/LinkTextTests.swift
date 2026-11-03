import Testing
import SwiftpolisBridge

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

    @Test("a shared page counts, unless shared text already holds links")
    func shared() {
        let list = "https://a/1\nhttps://a/2"
        #expect(LinkText.links(sharedTexts: [], urls: ["https://page"]) == ["https://page"])
        #expect(LinkText.links(sharedTexts: [list], urls: []) == ["https://a/1", "https://a/2"])
        #expect(LinkText.links(sharedTexts: [list], urls: ["https://page"]) == ["https://a/1", "https://a/2"])
        #expect(LinkText.links(sharedTexts: ["just a title"], urls: ["https://page"]) == ["https://page"])
    }

    @Test("what can't be downloaded isn't a shared link")
    func sharedNothing() {
        #expect(LinkText.links(sharedTexts: ["just words"], urls: ["file:///a.txt"]).isEmpty)
        #expect(LinkText.links(sharedTexts: [], urls: []).isEmpty)
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
