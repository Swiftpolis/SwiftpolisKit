import Foundation
import SwiftpolisDomain

/// One line of `--progress-template "download:%(progress)j"`.
struct YtDlpProgress: Equatable {
    enum Status: String {
        case downloading
        case finished
        case error
    }

    private struct Line: Decodable {
        var status: String?
        var downloadedBytes: Double?
        var totalBytes: Double?
        var totalBytesEstimate: Double?
        var speed: Double?
        var eta: Double?
        var fragmentIndex: Int?
        var fragmentCount: Int?
    }

    var status: Status
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var secondsRemaining: Double?
    /// `index/count`, shown in place of Connections.
    var fragments: String?

    init?(line: String) {
        guard line.hasPrefix("{") else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(Line.self, from: Data(line.utf8)),
              let status = decoded.status.flatMap(Status.init(rawValue:))
        else { return nil }

        self.status = status
        downloadedBytes = decoded.downloadedBytes.map { Int64($0) }
        totalBytes = (decoded.totalBytes ?? decoded.totalBytesEstimate).map { Int64($0) }
        bytesPerSecond = decoded.speed
        secondsRemaining = decoded.eta
        if let index = decoded.fragmentIndex, let count = decoded.fragmentCount {
            fragments = "\(index)/\(count)"
        }
    }
}

/// What yt-dlp is told about one Download.
///
/// Everything but the link goes in a private file, because a command line can be read by every
/// process on the Mac, and these can hold passwords.
struct YtDlpConfiguration {
    let link: String
    let outputPath: String
    let request: DownloadRequest
    let secrets: DownloadSecrets
    let settings: EngineSettings
    let cookieFile: String?
    let ffmpegPath: String?

    var arguments: [String] {
        var arguments = [
            "--no-playlist",
            "--no-warnings",
            "--quiet",
            "--progress",
            "--newline",
            "--continue",
            "--progress-template", "download:%(progress)j",
            "--retries", String(settings.maxTries),
            "--socket-timeout", String(Int(settings.timeout)),
            "--output", Self.outputTemplate(for: outputPath),
        ]
        arguments += Self.connectionArguments(request: request, secrets: secrets, settings: settings)
        if let cookieFile {
            arguments += ["--cookies", cookieFile]
        }
        if let ffmpegPath {
            arguments += ["--ffmpeg-location", ffmpegPath]
        }
        return arguments
    }

    /// The options that say how to reach a site. D31: Persepolis misnames several of these.
    static func connectionArguments(
        request: DownloadRequest,
        secrets: DownloadSecrets,
        settings: EngineSettings
    ) -> [String] {
        var arguments: [String] = []
        if let userAgent = request.userAgent {
            arguments += ["--user-agent", userAgent]
        }
        if let referer = request.referer {
            arguments += ["--referer", referer]
        }
        if let headers = request.headers {
            for (name, value) in RequestText.headers(from: headers) {
                arguments += ["--add-headers", "\(name):\(value)"]
            }
        }
        if !settings.verifiesCertificates {
            arguments.append("--no-check-certificates")
        }
        if let proxy = request.proxy {
            arguments += ["--proxy", proxyAddress(proxy, password: secrets.proxyPassword)]
        }
        if let user = request.httpUser {
            arguments += ["--username", user, "--password", secrets.httpPassword ?? ""]
        }
        return arguments
    }

    /// The whole command, with the link last so nothing in it can be read as an option.
    static func commandLine(configFile: String, link: String) -> [String] {
        ["--ignore-config", "--config-locations", configFile, "--", link]
    }

    /// yt-dlp reads `--output` as a template, so any percent sign in a name has to be escaped.
    static func outputTemplate(for path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%%")
    }

    /// Text for a yt-dlp config file, which is read with shell-style quoting.
    static func fileText(for arguments: [String]) -> String {
        let quoted = arguments.map { argument in
            let escaped = argument
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return quoted.joined(separator: " ") + "\n"
    }

    /// A cookie file from a browser's `Cookie` header. The header doesn't say which site the cookies
    /// belong to, so they're given to the link's own site and its subdomains.
    static func netscapeCookies(header: String, link: String) -> String {
        var host = URL(string: link)?.host() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }

        var text = "# Netscape HTTP Cookie File\n"
        for pair in header.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            text += ".\(host)\tTRUE\t/\tFALSE\t0\t\(name)\t\(value)\n"
        }
        return text
    }

    private static func proxyAddress(_ proxy: ProxySettings, password: String?) -> String {
        var login = ""
        if let user = proxy.user {
            login = encoded(user) + ":" + encoded(password ?? "") + "@"
        }
        return "\(proxy.kind.rawValue)://\(login)\(proxy.host):\(proxy.port)"
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}

/// The files yt-dlp keeps beside a file while it works on it.
public enum YtDlpPartials {
    public static func isPartial(_ file: String, of name: String) -> Bool {
        file == "\(name).part"
            || file == "\(name).ytdl"
            || file.hasPrefix("\(name).part-Frag")
            || file.hasPrefix("\(name).temp.")
    }
}

/// What Muxing turns two streams into.
public enum MuxPlan {
    private static let videoMarker = "_video"

    /// The combined file's name, from the video stream's. A `.webm` video with some other audio
    /// wouldn't be a valid `.webm`, so it becomes `.mkv`.
    static func finalName(videoPath: String) -> String {
        let last = URL(filePath: videoPath).lastPathComponent
        let name = last.removingPercentEncoding ?? last
        let dot = name.lastIndex(of: ".") ?? name.endIndex
        var stem = String(name[..<dot])
        var fileExtension = String(name[dot...])
        if stem.hasSuffix(videoMarker) { stem.removeLast(videoMarker.count) }
        if fileExtension.lowercased() == ".webm" { fileExtension = ".mkv" }
        return stem + fileExtension
    }

    static func arguments(video: String, audio: String, output: String) -> [String] {
        [
            "-i", video, "-i", audio, "-c", "copy", "-shortest", "-map", "0:v:0", "-map", "1:a:0",
            "-loglevel", "error", "-strict", "-2", output,
        ]
    }
}
