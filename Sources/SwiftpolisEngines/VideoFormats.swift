import Foundation
import SwiftpolisDomain

/// One choice in a Video Finder list.
public struct VideoFormat: Hashable, Identifiable, Sendable {
    public let id: String
    public let url: String
    public let fileExtension: String
    /// False for a playlist or manifest, which only yt-dlp can follow.
    public let isDirect: Bool
    public let sizeBytes: Int64?
    /// What the list shows, without the size.
    let description: String
    let qualityPrefix: String

    public var label: String {
        let parts = [description, sizeBytes.map(ByteFormat.size), isPlaylist ? "m3u8" : nil].compactMap { $0 }
        return qualityPrefix + parts.joined(separator: " ")
    }

    /// The same format, once a size has been found for it.
    public func withSize(_ size: Int64) -> VideoFormat {
        VideoFormat(
            id: id,
            url: url,
            fileExtension: fileExtension,
            isDirect: isDirect,
            sizeBytes: size,
            description: description,
            qualityPrefix: qualityPrefix
        )
    }

    public var isPlaylist: Bool {
        URL(string: url)?.pathExtension.lowercased() == "m3u8"
    }
}

/// What yt-dlp found at a link, in Persepolis's three lists. yt-dlp lists formats worst first.
public struct VideoFormats: Hashable, Sendable {
    private struct Info: Decodable {
        var title: String?
        var duration: Double?
        var thumbnail: String?
        var formats: [Format]?
        var entries: [Info?]?
        var format: String?
        // Set when the result is one format rather than a list of them.
        var formatId: String?
        var url: String?
        var ext: String?
        var acodec: String?
        var vcodec: String?
        var abr: Double?
        var height: Double?
        var filesize: Double?
        var filesizeApprox: Double?
        var httpHeaders: [String: String]?
        var protocolName: String?

        enum CodingKeys: String, CodingKey {
            case title, duration, thumbnail, formats, entries, format, formatId, url, ext, acodec, vcodec, abr, height
            case filesize, filesizeApprox, httpHeaders
            case protocolName = "protocol"
        }

        var asFormat: Format {
            Format(
                formatId: formatId, url: url, ext: ext, acodec: acodec, vcodec: vcodec, abr: abr, height: height,
                filesize: filesize, filesizeApprox: filesizeApprox, httpHeaders: httpHeaders,
                protocolName: protocolName, formatNote: nil
            )
        }
    }

    private struct Format: Decodable {
        var formatId: String?
        var url: String?
        var ext: String?
        var acodec: String?
        var vcodec: String?
        var abr: Double?
        var height: Double?
        var filesize: Double?
        var filesizeApprox: Double?
        var httpHeaders: [String: String]?
        var protocolName: String?
        var formatNote: String?

        enum CodingKeys: String, CodingKey {
            case formatId, url, ext, acodec, vcodec, abr, height, filesize, filesizeApprox, httpHeaders, formatNote
            case protocolName = "protocol"
        }

        var isDirect: Bool {
            guard let protocolName else { return !hasPlaylistLink }
            return ["http", "https"].contains(protocolName) && !hasPlaylistLink
        }

        private var hasPlaylistLink: Bool {
            guard let fileExtension = url.flatMap(URL.init(string:))?.pathExtension.lowercased() else { return false }
            return ["m3u8", "mpd"].contains(fileExtension)
        }

        /// A storyboard is a sheet of preview pictures, not something to download.
        var isStoryboard: Bool {
            ext == "mhtml" || formatNote == "storyboard"
        }

        func choice(qualityPrefix: String = "") -> VideoFormat? {
            guard let url else { return nil }
            var pieces: [String] = []
            if vcodec == "none" {
                if let abr { pieces.append(Self.number(abr) + "kbps") }
            } else if let height {
                pieces.append(Self.number(height) + "p")
            }
            if let ext { pieces.append("." + ext) }
            return VideoFormat(
                id: formatId ?? url,
                url: url,
                fileExtension: ext ?? "mp4",
                isDirect: isDirect,
                sizeBytes: (filesize ?? filesizeApprox).map { Int64($0) },
                description: pieces.joined(separator: " "),
                qualityPrefix: qualityPrefix
            )
        }

        private static func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    private static let maximumNameLength = 20
    private static let fallbackName = "Video finder"

    public let title: String?
    public let durationSeconds: Double?
    public let thumbnail: String?
    public private(set) var combined: [VideoFormat]
    public private(set) var videoOnly: [VideoFormat]
    public private(set) var audioOnly: [VideoFormat]
    public let userAgent: String?
    public let referer: String?
    public let headers: String?

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let info = try decoder.decode(Info.self, from: json)

        var raw: [Format]
        if let formats = info.formats {
            raw = formats
        } else if let first = info.entries?.compactMap({ $0 }).first {
            raw = first.formats ?? []
        } else if info.format != nil {
            raw = [info.asFormat]
        } else {
            raw = []
        }
        raw.removeAll(where: \.isStoryboard)

        title = info.title ?? info.entries?.compactMap({ $0 }).first?.title
        durationSeconds = info.duration
        thumbnail = info.thumbnail

        let isVideoOnly: (Format) -> Bool = { $0.acodec == "none" }
        let isAudioOnly: (Format) -> Bool = { $0.vcodec == "none" && $0.acodec != "none" }
        videoOnly = raw.filter(isVideoOnly).compactMap { $0.choice() }
        audioOnly = raw.filter(isAudioOnly).compactMap { $0.choice() }

        let bothKinds = raw.filter { !isVideoOnly($0) && !isAudioOnly($0) }
        combined = bothKinds.enumerated().compactMap { index, format in
            var prefix = ""
            if bothKinds.count > 1 {
                if index == 0 { prefix = "Worst quality: " }
                if index == bothKinds.count - 1 { prefix = "Best quality: " }
            }
            return format.choice(qualityPrefix: prefix)
        }

        var kept = raw.last { $0.httpHeaders != nil }?.httpHeaders ?? [:]
        userAgent = kept.removeValue(forKey: "User-Agent")
        referer = kept.removeValue(forKey: "Referer")
        headers = kept.isEmpty
            ? nil
            : kept.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    /// The name Video Finder suggests: the start of the title, safe to use as a file name.
    public var suggestedName: String {
        guard let title else { return Self.fallbackName }
        let name = title.prefix(Self.maximumNameLength)
            .replacing(/[\/\\:]/, with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Self.fallbackName : name
    }

    /// The same lists, with a size filled in for one format.
    public func settingSize(_ size: Int64, forFormat id: String) -> VideoFormats {
        func updated(_ list: [VideoFormat]) -> [VideoFormat] {
            list.map { $0.id == id ? $0.withSize(size) : $0 }
        }
        var result = self
        result.combined = updated(combined)
        result.videoOnly = updated(videoOnly)
        result.audioOnly = updated(audioOnly)
        return result
    }

    public var hasSeparateStreams: Bool { !videoOnly.isEmpty || !audioOnly.isEmpty }
}
