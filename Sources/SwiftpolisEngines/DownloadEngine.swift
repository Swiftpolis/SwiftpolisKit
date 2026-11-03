import Foundation
import SwiftpolisDomain

/// One Download being fetched. HTTP, yt-dlp and torrent downloads all have this shape.
public protocol DownloadEngine: Sendable {
    /// Runs until the Download completes, fails or is stopped. Cancelling the task stops it.
    func run() async
    func pause()
    func unpause()
    func stop()
    func setSpeedDial(_ dial: Int)
    var snapshot: DownloadSnapshot { get }
}

/// An engine the system itself can hold back until a Start time, even with the app gone.
public protocol SelfSchedulingEngine: DownloadEngine {
    func begin(notBefore date: Date)
}

/// The preferences an engine needs. Defaults match Persepolis's.
public struct EngineSettings: Sendable {
    public var timeout: TimeInterval = 10
    public var maxTries = 5
    public var retryWait: TimeInterval = 5
    public var chunkSizeKiB = 100
    public var verifiesCertificates = true
    public var defaultFolder: String?
    public var usesSubfolders = true
    public var userAgent = "Swiftpolis/1.0"
    public var allowsCellularData = true

    public init() {}
}

/// What one Download must keep private. This comes from the Keychain and is never stored with it.
public struct DownloadSecrets: Sendable {
    public var proxyPassword: String?
    public var httpPassword: String?
    /// The cookies a browser sent with this link, as a `Cookie` header's value.
    public var cookieHeader: String?

    public init(proxyPassword: String? = nil, httpPassword: String? = nil, cookieHeader: String? = nil) {
        self.proxyPassword = proxyPassword
        self.httpPassword = httpPassword
        self.cookieHeader = cookieHeader
    }
}

public struct DownloadSnapshot: Hashable, Sendable {
    public var status: DownloadStatus
    public var fileName: String?
    public var filePath: String?
    public var totalBytes: Int64?
    public var downloadedBytes: Int64
    public var activeConnections: Int
    public var bytesPerSecond: Double
    public var secondsRemaining: Double?
    public var errorMessage: String?
    /// `index/count`. yt-dlp has these in place of Connections.
    public var fragments: String?

    public init(
        status: DownloadStatus,
        fileName: String?,
        filePath: String?,
        totalBytes: Int64?,
        downloadedBytes: Int64,
        activeConnections: Int,
        bytesPerSecond: Double,
        secondsRemaining: Double?,
        errorMessage: String?,
        fragments: String? = nil
    ) {
        self.status = status
        self.fileName = fileName
        self.filePath = filePath
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.activeConnections = activeConnections
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
        self.errorMessage = errorMessage
        self.fragments = fragments
    }

    public var percent: Int {
        if status == .complete { return 100 }
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return Int(downloadedBytes * 100 / totalBytes)
    }
}
