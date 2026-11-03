import Foundation

public enum LinkText {
    /// The links in a piece of text, one per line as in a text file of links. A single-line field can
    /// turn a list's line breaks into spaces, so a space before another link separates them too.
    public static func links(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .flatMap { $0.split(separator: /\s+(?=https?:\/\/)/) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(looksLikeLink)
    }

    /// The links in what another app shared. Text that holds links stands for itself, so when an app shares
    /// a selection along with the page it came from, the page isn't one of the links.
    public static func links(sharedTexts texts: [String], urls: [String]) -> [String] {
        let fromTexts = links(in: texts.joined(separator: "\n"))
        return fromTexts.isEmpty ? links(in: urls.joined(separator: "\n")) : fromTexts
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
