import Foundation

/// One link from a browser, with what's needed to fetch it as that browser would.
public struct BrowserLink: Codable, Equatable, Sendable {
    public var url: String
    public var cookies: String?
    public var userAgent: String?
    public var referrer: String?
    public var fileName: String?
    public var headers: String?
    public var cookieFilePath: String?

    public init(
        url: String,
        cookies: String? = nil,
        userAgent: String? = nil,
        referrer: String? = nil,
        fileName: String? = nil,
        headers: String? = nil,
        cookieFilePath: String? = nil
    ) {
        self.url = url
        self.cookies = cookies
        self.userAgent = userAgent
        self.referrer = referrer
        self.fileName = fileName
        self.headers = headers
        self.cookieFilePath = cookieFilePath
    }
}

/// The JSON the browser extensions send. See docs/browser-integration.md.
public enum BrowserMessage {
    public static func links(from data: Data) -> [BrowserLink] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return links(fromMessage: json)
    }

    /// Reads a message that has already been decoded, as Safari hands it to its handler.
    public static func links(fromMessage message: [String: Any]) -> [BrowserLink] {
        guard let items = message["url_links"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            func text(_ key: String) -> String? {
                guard let value = item[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            guard let url = text("url") else { return nil }
            return BrowserLink(
                url: url,
                cookies: text("cookies"),
                userAgent: text("useragent"),
                referrer: text("referrer"),
                fileName: text("filename").map { URL(filePath: $0).lastPathComponent },
                headers: text("header"),
                cookieFilePath: text("load_cookies")
            )
        }
    }
}

/// Chrome and Firefox talk to a helper over stdin and stdout, using length-prefixed messages.
public enum NativeMessaging {
    /// What Persepolis replies, so an extension can tell the host is there.
    public static let reply = Data(#"{"enable": true, "version": "1.85"}"#.utf8)

    private static let maximumLength = 64 * 1_024 * 1_024

    public static func frame(_ message: Data) -> Data {
        withUnsafeBytes(of: UInt32(message.count).littleEndian) { Data($0) } + message
    }

    /// Reads one message. Returns `nil` at the end of the input, or if the length makes no sense.
    public static func readFrame(from handle: FileHandle) -> Data? {
        guard let header = read(4, from: handle) else { return nil }
        let length = header.reversed().reduce(0) { $0 << 8 | Int($1) }
        guard length <= maximumLength else { return nil }
        return read(length, from: handle)
    }

    private static func read(_ count: Int, from handle: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let piece = try? handle.read(upToCount: count - data.count), !piece.isEmpty else { return nil }
            data.append(piece)
        }
        return data
    }
}
