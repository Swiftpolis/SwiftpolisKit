import Foundation
import Synchronization
import SwiftpolisDomain

/// Where the bundled helpers are. A missing one is `nil`, so that Video Finder can say so.
public struct HelperPaths: Sendable {
    public var ytDlp: String?
    public var ffmpeg: String?
    public var deno: String?

    public init(ytDlp: String? = nil, ffmpeg: String? = nil, deno: String? = nil) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.deno = deno
    }
}

/// A private folder for what yt-dlp is told, which can hold passwords and cookies.
final class YtDlpWorkFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "swiftpolis-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func write(_ text: String, named name: String) throws -> String {
        let path = url.appending(path: name, directoryHint: .notDirectory).path
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        return path
    }

    /// yt-dlp saves its cookies back over the file it read, so it's only ever given a copy.
    func cookieFile(request: DownloadRequest, secrets: DownloadSecrets, link: String) throws -> String? {
        var text = ""
        if let path = request.cookieFilePath, let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            text = contents
        }
        if let header = secrets.cookieHeader {
            let browser = YtDlpConfiguration.netscapeCookies(header: header, link: link)
            text = text.isEmpty ? browser : text + "\n" + browser
        }
        return text.isEmpty ? nil : try write(text, named: "cookies.txt")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Fetches a stream or playlist by running yt-dlp. It can only be stopped and started again, so
/// pausing and the speed dial do nothing, as in Persepolis.
public final class YtDlpEngine: DownloadEngine {
    private struct State {
        var status = DownloadStatus.waiting
        var fileName: String?
        var filePath: String?
        var totalBytes: Int64?
        var downloadedBytes: Int64 = 0
        var bytesPerSecond = 0.0
        var secondsRemaining: Double?
        var fragments: String?
        var errorMessage: String?
        var process: HelperProcess?
    }

    private static let playlistExtension = ".m3u8"

    private let request: DownloadRequest
    private let secrets: DownloadSecrets
    private let settings: EngineSettings
    private let helpers: HelperPaths
    private let state: Mutex<State>

    public init(request: DownloadRequest, secrets: DownloadSecrets, settings: EngineSettings, helpers: HelperPaths) {
        self.request = request
        self.secrets = secrets
        self.settings = settings
        self.helpers = helpers
        state = Mutex(State(fileName: request.customFileName))
    }

    public func run() async {
        await withTaskCancellationHandler {
            await perform()
        } onCancel: {
            stop()
        }
    }

    public func pause() {}
    public func unpause() {}
    public func setSpeedDial(_ dial: Int) {}

    public func stop() {
        let process = state.withLock { state -> HelperProcess? in
            if state.status != .complete, state.status != .error { state.status = .stopped }
            return state.process
        }
        process?.stop()
    }

    public var snapshot: DownloadSnapshot {
        state.withLock { state in
            DownloadSnapshot(
                status: state.status,
                fileName: state.fileName,
                filePath: state.filePath,
                totalBytes: state.totalBytes,
                downloadedBytes: state.downloadedBytes,
                activeConnections: 0,
                bytesPerSecond: state.bytesPerSecond,
                secondsRemaining: state.secondsRemaining,
                errorMessage: state.errorMessage,
                fragments: state.fragments
            )
        }
    }

    private func perform() async {
        guard let ytDlp = helpers.ytDlp else {
            fail("yt-dlp is missing from this copy of Swiftpolis")
            return
        }

        let name: String
        let outputPath: String
        let work: YtDlpWorkFolder
        let process: HelperProcess
        do {
            let folder = URL(filePath: request.folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            name = Self.outputName(for: request, in: folder)
            outputPath = folder.appending(path: name, directoryHint: .notDirectory).path

            work = try YtDlpWorkFolder()
            let configuration = YtDlpConfiguration(
                link: request.link,
                outputPath: outputPath,
                request: request,
                secrets: secrets,
                settings: settings,
                cookieFile: try work.cookieFile(request: request, secrets: secrets, link: request.link),
                ffmpegPath: helpers.ffmpeg
            )
            let configFile = try work.write(YtDlpConfiguration.fileText(for: configuration.arguments), named: "yt-dlp.conf")
            process = HelperProcess(
                path: ytDlp,
                arguments: YtDlpConfiguration.commandLine(configFile: configFile, link: request.link)
            ) { [weak self] line in
                self?.receive(line)
            }
        } catch {
            fail("Can't create the file")
            return
        }
        defer { work.remove() }

        let canStart = state.withLock { state -> Bool in
            guard state.status != .stopped else { return false }
            state.status = .downloading
            state.fileName = name
            state.process = process
            return true
        }
        guard canStart else { return }

        let ending = await process.run()
        finish(ending, name: name, path: outputPath)
    }

    /// The file's name. A finished file already there is left alone, by using another name, but a
    /// partial one is this Download's own and gets resumed.
    private static func outputName(for request: DownloadRequest, in folder: URL) -> String {
        var name = FileNaming.resolve(custom: request.customFileName, contentDisposition: nil, link: request.link)
        // The result is a video, whatever the playlist that led to it was called.
        if name.lowercased().hasSuffix(playlistExtension) {
            name = String(name.dropLast(playlistExtension.count)) + ".mp4"
        }
        return FileNaming.unique(FileNaming.fittingFileSystem(name)) { candidate in
            FileManager.default.fileExists(atPath: folder.appending(path: candidate).path)
        }
    }

    private func receive(_ line: String) {
        guard let progress = YtDlpProgress(line: line) else { return }
        state.withLock { state in
            if let downloaded = progress.downloadedBytes { state.downloadedBytes = downloaded }
            if let total = progress.totalBytes { state.totalBytes = total }
            state.bytesPerSecond = progress.bytesPerSecond ?? 0
            state.secondsRemaining = progress.secondsRemaining
            if progress.status == .downloading { state.fragments = progress.fragments }
        }
    }

    private func finish(_ ending: HelperProcess.Ending, name: String, path: String) {
        let manager = FileManager.default
        let wasStopped = state.withLock { state -> Bool in
            state.process = nil
            state.bytesPerSecond = 0
            state.secondsRemaining = nil
            state.fragments = nil
            return state.status == .stopped
        }
        if wasStopped { return }

        guard ending.exitCode == 0, manager.fileExists(atPath: path) else {
            fail(Self.errorMessage(from: ending.errorText))
            return
        }

        let moved = FinishedFile.moveToSubfolder(name: name, path: path, request: request, settings: settings)
        let size = (try? manager.attributesOfItem(atPath: moved.path))?[.size] as? Int64
        state.withLock { state in
            state.status = .complete
            state.fileName = moved.name
            state.filePath = moved.path
            if let size {
                state.totalBytes = size
                state.downloadedBytes = size
            }
        }
    }

    private func fail(_ message: String) {
        state.withLock { state in
            state.status = .error
            state.errorMessage = message
        }
    }

    /// The last thing yt-dlp called an error, which is the one that ended it.
    static func errorMessage(from errorText: String) -> String {
        let prefix = "ERROR: "
        let lastError = errorText.split(whereSeparator: \.isNewline).last { $0.hasPrefix(prefix) }
        return lastError.map { String($0.dropFirst(prefix.count)) } ?? "Download error"
    }
}

/// What to do with a file once it has finished.
enum FinishedFile {
    /// Moves a finished file into its subfolder if it's in the default folder. If the move fails,
    /// the file stays where it is, as in Persepolis.
    static func moveToSubfolder(
        name: String,
        path: String,
        request: DownloadRequest,
        settings: EngineSettings
    ) -> (name: String, path: String) {
        guard settings.usesSubfolders, settings.defaultFolder == request.folder else { return (name, path) }

        let folder = URL(filePath: request.folder, directoryHint: .isDirectory)
            .appending(path: FileClassifier.subfolder(for: name), directoryHint: .isDirectory)
        let manager = FileManager.default
        let newName = FileNaming.unique(name) { candidate in
            manager.fileExists(atPath: folder.appending(path: candidate).path)
        }
        let destination = folder.appending(path: newName, directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.moveItem(atPath: path, toPath: destination.path)
            return (newName, destination.path)
        } catch {
            return (name, path)
        }
    }
}

/// Asks yt-dlp what a link offers.
public enum VideoExtractor {
    public struct Failure: Error, Equatable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    public static func formats(
        at link: String,
        request: DownloadRequest,
        secrets: DownloadSecrets,
        settings: EngineSettings,
        helpers: HelperPaths
    ) async throws -> VideoFormats {
        guard let ytDlp = helpers.ytDlp else {
            throw Failure(message: "yt-dlp is missing from this copy of Swiftpolis")
        }
        let work: YtDlpWorkFolder
        var arguments = ["--no-playlist", "--no-warnings", "--dump-single-json", "--socket-timeout", "5"]
        do {
            work = try YtDlpWorkFolder()
            arguments += YtDlpConfiguration.connectionArguments(request: request, secrets: secrets, settings: settings)
            if let cookies = try work.cookieFile(request: request, secrets: secrets, link: link) {
                arguments += ["--cookies", cookies]
            }
            if let deno = helpers.deno {
                arguments += ["--js-runtimes", "deno:\(deno)"]
            }
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        defer { work.remove() }

        let configFile: String
        do {
            configFile = try work.write(YtDlpConfiguration.fileText(for: arguments), named: "yt-dlp.conf")
        } catch {
            throw Failure(message: error.localizedDescription)
        }

        let ending = await HelperProcess(
            path: ytDlp,
            arguments: YtDlpConfiguration.commandLine(configFile: configFile, link: link)
        ).run()
        try Task.checkCancellation()
        guard ending.exitCode == 0 else {
            throw Failure(message: YtDlpEngine.errorMessage(from: ending.errorText))
        }
        do {
            return try VideoFormats(json: ending.output)
        } catch {
            throw Failure(message: "yt-dlp's answer couldn't be read")
        }
    }

    /// Fetches a thumbnail by the same route as the video, so a proxy applies to it too.
    public static func thumbnail(
        at link: String,
        request: DownloadRequest,
        secrets: DownloadSecrets,
        settings: EngineSettings
    ) async -> Data? {
        var pictureRequest = request
        pictureRequest.link = link
        pictureRequest.referer = nil
        pictureRequest.headers = nil
        pictureRequest.httpUser = nil
        pictureRequest.cookieFilePath = nil
        var pictureSecrets = secrets
        pictureSecrets.cookieHeader = nil
        pictureSecrets.httpPassword = nil

        let requests = RequestFactory(request: pictureRequest, secrets: pictureSecrets, settings: settings)
        let session = requests.makeSession(delegate: RequestPolicyDelegate(requests: requests), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try? await session.data(for: requests.make(method: "GET")).0
    }
}

/// Combines a video stream and an audio stream into one file.
public enum VideoMuxer {
    public enum Failure: Error, Equatable {
        case notEnoughSpace(folder: String)
        case failed(message: String)
    }

    public struct Output: Equatable, Sendable {
        public let fileName: String
        public let path: String
        public let bytes: Int64

        public init(fileName: String, path: String, bytes: Int64) {
            self.fileName = fileName
            self.path = path
            self.bytes = bytes
        }
    }

    /// Where a muxed file goes: `Videos` if the Download was in the default folder.
    public static func folder(forDownloadIn folder: String, settings: EngineSettings) -> String {
        guard settings.usesSubfolders, settings.defaultFolder == folder else { return folder }
        return URL(filePath: folder, directoryHint: .isDirectory)
            .appending(path: "Videos", directoryHint: .isDirectory).path
    }

    /// Writes to `folder`, under a new name if the plain one is taken.
    public static func mux(
        video: String,
        audio: String,
        folder: String,
        ffmpeg: String?,
        availableBytes: Int64? = nil
    ) async throws(Failure) -> Output {
        guard let ffmpeg else {
            throw .failed(message: "ffmpeg is missing from this copy of Swiftpolis")
        }
        let manager = FileManager.default
        let folderURL = URL(filePath: folder, directoryHint: .isDirectory)

        func size(_ path: String) -> Int64 {
            ((try? manager.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
        }

        do {
            try manager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw .failed(message: error.localizedDescription)
        }

        let available = availableBytes ?? (try? folderURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity
            .map(Int64.init)
        if let available, size(video) + size(audio) > available {
            throw .notEnoughSpace(folder: folder)
        }

        let name = FileNaming.unique(MuxPlan.finalName(videoPath: video)) { candidate in
            manager.fileExists(atPath: folderURL.appending(path: candidate).path)
        }
        let output = folderURL.appending(path: name, directoryHint: .notDirectory).path

        let ending = await HelperProcess(
            path: ffmpeg,
            arguments: MuxPlan.arguments(video: video, audio: audio, output: output)
        ).run()
        guard ending.exitCode == 0, manager.fileExists(atPath: output) else {
            // What's there is unusable, and leaving it would take the name from the next try.
            try? manager.removeItem(atPath: output)
            let message = ending.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw .failed(message: message.isEmpty ? "muxing error" : message)
        }
        return Output(fileName: name, path: output, bytes: size(output))
    }
}
