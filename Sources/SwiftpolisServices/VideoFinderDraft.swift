import Foundation
import SwiftpolisBridge
import SwiftpolisDomain
import SwiftpolisEngines

/// What the Video Finder window edits: the formats found at a link, which of them to fetch, and the
/// same options as any other Download.
public struct VideoFinderDraft: Equatable, Sendable {
    public enum MediaChoice: Hashable, Sendable {
        /// The best video stream with the best audio stream, as a Video pair.
        case bestQuality
        case combined(Int)
    }

    public enum Plan: Sendable {
        case single(DownloadRequest, DownloadSecrets)
        case pair(video: DownloadRequest, audio: DownloadRequest, DownloadSecrets)
    }

    private static let defaultName = "video_finder_file"
    private static let defaultExtension = ".mp4"

    public var options: DownloadDraft
    public private(set) var formats: VideoFormats?
    public var mediaChoice = MediaChoice.combined(0)
    public var usesSeparateStreams = false
    /// An index into the video-only list. `nil` is "No video".
    public var videoChoice: Int?
    /// An index into the audio-only list. `nil` is "No audio".
    public var audioChoice: Int?
    public var changesName = false
    public var name = ""

    public init(options: DownloadDraft) {
        self.options = options
    }

    /// Takes in what was found, and picks the best of it.
    public mutating func apply(_ found: VideoFormats) {
        formats = found
        videoChoice = found.videoOnly.indices.last
        audioChoice = found.audioOnly.indices.last

        if !found.videoOnly.isEmpty, !found.audioOnly.isEmpty {
            mediaChoice = .bestQuality
        } else if let last = found.combined.indices.last {
            mediaChoice = .combined(last)
        }
        usesSeparateStreams = found.combined.isEmpty && found.hasSeparateStreams

        name = found.suggestedName
        changesName = true

        if let userAgent = found.userAgent { options.userAgent = userAgent }
        if let referer = found.referer { options.referer = referer }
        if let headers = found.headers { options.headers = headers }
    }

    /// The same formats, now with a size a Spider found for one of them.
    public mutating func updateFormats(_ updated: VideoFormats) {
        formats = updated
    }

    public var hasBestQualityChoice: Bool {
        guard let formats else { return false }
        return !formats.videoOnly.isEmpty && !formats.audioOnly.isEmpty
    }

    public var showsMediaPicker: Bool {
        guard let formats else { return false }
        return !formats.combined.isEmpty
    }

    /// Whether the user can switch to choosing streams. With no combined formats, they have to.
    public var canChooseSeparateStreams: Bool {
        guard let formats else { return false }
        return formats.hasSeparateStreams && !formats.combined.isEmpty
    }

    private var chosenVideo: VideoFormat? { videoChoice.flatMap { formats?.videoOnly[safe: $0] } }
    private var chosenAudio: VideoFormat? { audioChoice.flatMap { formats?.audioOnly[safe: $0] } }

    /// The extension shown beside the name, from the first stream that will be fetched.
    public var fileExtension: String {
        guard let formats else { return Self.defaultExtension }
        var format: VideoFormat?
        if usesSeparateStreams {
            format = chosenVideo ?? chosenAudio
        } else {
            switch mediaChoice {
            case .bestQuality: format = formats.videoOnly.last
            case .combined(let index): format = formats.combined[safe: index]
            }
        }
        return format.map { "." + $0.fileExtension } ?? Self.defaultExtension
    }

    /// What to add. `nil` means nothing was chosen, and the window just closes.
    public var plan: Plan? {
        guard let formats else { return nil }
        if usesSeparateStreams {
            switch (chosenVideo, chosenAudio) {
            case (let video?, let audio?): return pair(video: video, audio: audio)
            case (let video?, nil): return single(video)
            case (nil, let audio?): return single(audio)
            case (nil, nil): return nil
            }
        }
        switch mediaChoice {
        case .bestQuality:
            guard let video = formats.videoOnly.last, let audio = formats.audioOnly.last else { return nil }
            return pair(video: video, audio: audio)
        case .combined(let index):
            return formats.combined[safe: index].map(single)
        }
    }

    private var baseName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return changesName && !typed.isEmpty ? typed : Self.defaultName
    }

    private func draft(for format: VideoFormat, name: String) -> DownloadDraft {
        var draft = options
        draft.link = format.url
        draft.changesName = true
        draft.customName = name
        if draft.referer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.referer = options.link.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return draft
    }

    private func single(_ format: VideoFormat) -> Plan {
        var draft = draft(for: format, name: baseName + fileExtension)
        // D34: only yt-dlp can follow a playlist or a manifest.
        if !format.isDirect { draft.engine = .ytDlp }
        return .single(draft.request, draft.secrets)
    }

    private func pair(video: VideoFormat, audio: VideoFormat) -> Plan {
        var videoDraft = draft(for: video, name: "\(baseName)_video.\(video.fileExtension)")
        videoDraft.engine = .ytDlp
        var audioDraft = draft(for: audio, name: "\(baseName)_audio.\(audio.fileExtension)")
        audioDraft.engine = .ytDlp
        // The video runs first, so it's the one that waits for the Start time.
        audioDraft.usesStartTime = false
        return .pair(video: videoDraft.request, audio: audioDraft.request, videoDraft.secrets)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Where a Browser request's links go. Video Finder takes up to its limit, and the rest are ordinary.
public struct BrowserRequestPlan: Equatable, Sendable {
    public let videoFinder: [BrowserLink]
    public let route: BrowserRequestRoute?

    public init(links: [BrowserLink], startsImmediately: Bool, videoFinderMaxLinks: Int) {
        var forVideoFinder: [BrowserLink] = []
        var others: [BrowserLink] = []
        for link in links {
            if forVideoFinder.count < videoFinderMaxLinks, VideoSites.isSupported(link.url) {
                forVideoFinder.append(link)
            } else {
                others.append(link)
            }
        }
        videoFinder = forVideoFinder
        route = BrowserRequestRoute(links: others, startsImmediately: startsImmediately)
    }
}
