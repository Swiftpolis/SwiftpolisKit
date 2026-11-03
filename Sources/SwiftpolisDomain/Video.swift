import Foundation

/// Which program fetches a Download.
public enum DownloadEngineKind: String, Hashable, Sendable {
    case http
    case ytDlp

    /// Persepolis's rule: a name ending in `.m3u8` is a playlist, which only yt-dlp can follow.
    public init(customFileName: String?) {
        let fileExtension = customFileName?.split(separator: ".").last?.lowercased()
        self = fileExtension == "m3u8" ? .ytDlp : .http
    }
}

public enum MuxingStatus: String, Hashable, Sendable {
    case notStarted
    case muxing
    case complete
    case error
}

/// A video stream and an audio stream, downloaded separately and then combined into one file.
public struct VideoPair: Hashable, Sendable {
    public let videoGID: GID
    public let audioGID: GID
    public var muxingStatus: MuxingStatus

    public init(videoGID: GID, audioGID: GID, muxingStatus: MuxingStatus) {
        self.videoGID = videoGID
        self.audioGID = audioGID
        self.muxingStatus = muxingStatus
    }

    public func contains(_ gid: GID) -> Bool {
        gid == videoGID || gid == audioGID
    }

    public func partner(of gid: GID) -> GID {
        gid == videoGID ? audioGID : videoGID
    }
}

/// The sites whose links go to Video Finder rather than Add Link.
public enum VideoSites {
    private static let patterns = [
        "youtube.com/watch",
        "aparat.com/v/",
        "vimeo.com/",
        "dailymotion.com/video",
        "https://soundcloud.com/",
    ]

    public static func isSupported(_ link: String) -> Bool {
        patterns.contains { link.contains($0) }
    }
}
