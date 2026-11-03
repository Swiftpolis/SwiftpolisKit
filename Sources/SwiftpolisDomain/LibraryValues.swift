import Foundation

/// The options a Download was added with. Passwords are not here: they belong in the Keychain.
public struct DownloadRequest: Hashable, Sendable {
    public var link: String
    public var customFileName: String?
    public var folder: String
    public var connections: Int
    public var speedDial: Int
    public var startTime: ClockTime?
    public var endTime: ClockTime?
    public var proxy: ProxySettings?
    public var httpUser: String?
    public var referer: String?
    public var userAgent: String?
    public var headers: String?
    public var cookieFilePath: String?
    public var shutsDownAfterDownload: Bool
    public var engine: DownloadEngineKind

    public init(
        link: String,
        customFileName: String? = nil,
        folder: String,
        connections: Int,
        speedDial: Int = 10,
        startTime: ClockTime? = nil,
        endTime: ClockTime? = nil,
        proxy: ProxySettings? = nil,
        httpUser: String? = nil,
        referer: String? = nil,
        userAgent: String? = nil,
        headers: String? = nil,
        cookieFilePath: String? = nil,
        shutsDownAfterDownload: Bool = false,
        engine: DownloadEngineKind = .http
    ) {
        self.link = link
        self.customFileName = customFileName
        self.folder = folder
        self.connections = connections
        self.speedDial = speedDial
        self.startTime = startTime
        self.endTime = endTime
        self.proxy = proxy
        self.httpUser = httpUser
        self.referer = referer
        self.userAgent = userAgent
        self.headers = headers
        self.cookieFilePath = cookieFilePath
        self.shutsDownAfterDownload = shutsDownAfterDownload
        self.engine = engine
    }
}

public struct ProxySettings: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case http
        case socks5
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var user: String?

    public init(kind: Kind, host: String, port: Int, user: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
    }
}

/// A Queue's options. The clock values are kept when a flag is off, so the panel can show them.
public struct QueueOptions: Hashable, Sendable {
    public var startTimeEnabled = false
    public var startTime = ClockTime.midnight
    public var endTimeEnabled = false
    public var endTime = ClockTime.midnight
    public var isReversed = false
    public var shutsDownAfterDownload = false

    public init() {}
}

extension ClockTime {
    static let midnight = ClockTime(hour: 0, minute: 0)!
}

public struct CategorySummary: Hashable, Sendable {
    public let name: String
    public let kind: CategoryKind
    public let options: QueueOptions

    public init(name: String, kind: CategoryKind, options: QueueOptions) {
        self.name = name
        self.kind = kind
        self.options = options
    }
}

public struct DownloadSummary: Hashable, Sendable {
    public let gid: GID
    public let request: DownloadRequest
    public let status: DownloadStatus
    public let category: String
    public let fileName: String?
    /// Where a finished file ended up. Before that, it's `nil`.
    public let filePath: String?
    public let totalBytes: Int64?
    public let downloadedBytes: Int64
    public let firstTryDate: Date
    public let lastTryDate: Date

    public init(
        gid: GID,
        request: DownloadRequest,
        status: DownloadStatus,
        category: String,
        fileName: String?,
        filePath: String?,
        totalBytes: Int64?,
        downloadedBytes: Int64,
        firstTryDate: Date,
        lastTryDate: Date
    ) {
        self.gid = gid
        self.request = request
        self.status = status
        self.category = category
        self.fileName = fileName
        self.filePath = filePath
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.firstTryDate = firstTryDate
        self.lastTryDate = lastTryDate
    }
}

/// The part of a Download that changes while it runs and is worth saving.
public struct DownloadProgress: Hashable, Sendable {
    public var status: DownloadStatus
    public var fileName: String?
    public var totalBytes: Int64?
    public var downloadedBytes: Int64
    public var filePath: String?

    public init(
        status: DownloadStatus,
        fileName: String?,
        totalBytes: Int64?,
        downloadedBytes: Int64,
        filePath: String? = nil
    ) {
        self.status = status
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.filePath = filePath
    }
}

public enum LibraryError: Error, Equatable, Sendable {
    case categoryNotFound(String)
    case categoryCannotBeRemoved(String)
    case categoryNotAddable(String)
    case downloadNotFound(GID)
    case downloadIsActive(GID)
}
