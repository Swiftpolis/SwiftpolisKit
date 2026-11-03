import Foundation

/// What the toolbar and menus offer for a selected Download, from Persepolis's `checkSelectedRow`.
public struct DownloadActions: Equatable, Sendable {
    public var canResume = false
    public var canPause = false
    public var canStop = false
    public var canEditProperties = false
    public var canShowProgress = false
    public var canOpenFile = false
    public var canOpenFolder = false
    public var canMoveFile = false

    public init() {}

    public init(status: DownloadStatus, category: String, engine: DownloadEngineKind = .http) {
        if CategoryKind(categoryName: category) == .singleDownloads {
            applySingleDownload(status: status)
            // yt-dlp can only be stopped and started again.
            if engine == .ytDlp { canPause = false }
        } else {
            // A Queue's Downloads are controlled through the Queue, and pressing these says so.
            canResume = true
            canPause = true
            canStop = true
            applyFinishedActions(status: status)
        }
    }

    private mutating func applySingleDownload(status: DownloadStatus) {
        switch status {
        case .scheduled, .waiting:
            canStop = true
            canShowProgress = true
        case .downloading:
            canPause = true
            canStop = true
            canShowProgress = true
        case .paused:
            canResume = true
            canStop = true
            canShowProgress = true
        case .stopped, .error:
            canResume = true
            canEditProperties = true
        case .complete:
            applyFinishedActions(status: status)
        case .creatingDownloadFile:
            break
        }
    }

    private mutating func applyFinishedActions(status: DownloadStatus) {
        switch status {
        case .complete:
            canEditProperties = true
            canOpenFile = true
            canOpenFolder = true
            canMoveFile = true
        case .stopped, .error:
            canEditProperties = true
        default:
            break
        }
    }
}

extension DownloadStatus {
    public var canBeRemoved: Bool { canChangeCategory }
}

/// The fields a list can be sorted by.
public struct DownloadSortFields: Sendable {
    public var fileName: String?
    public var status: DownloadStatus
    public var totalBytes: Int64?
    public var firstTry: Date
    public var lastTry: Date

    public init(
        fileName: String?,
        status: DownloadStatus,
        totalBytes: Int64?,
        firstTry: Date,
        lastTry: Date
    ) {
        self.fileName = fileName
        self.status = status
        self.totalBytes = totalBytes
        self.firstTry = firstTry
        self.lastTry = lastTry
    }
}

public enum MoveDirection: Sendable {
    case up
    case down
}

public enum DownloadSortKey: String, CaseIterable, Sendable {
    case name
    case size
    case status
    case firstTry
    case lastTry

    public func sorted(_ items: [DownloadSortFields]) -> [DownloadSortFields] {
        sorted(items) { $0 }
    }

    /// Sorts top-of-list first. Items that compare equal keep their order, as in Persepolis.
    public func sorted<Item>(_ items: [Item], fields: (Item) -> DownloadSortFields) -> [Item] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, fields: fields($0.element)) }
            .sorted { first, second in
                switch compare(first.fields, second.fields) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: first.offset < second.offset
                }
            }
            .map(\.item)
    }

    private func compare(_ first: DownloadSortFields, _ second: DownloadSortFields) -> ComparisonResult {
        switch self {
        case .name:
            ascending(first.fileName ?? "", second.fileName ?? "")
        case .size:
            ascending(second.totalBytes ?? 0, first.totalBytes ?? 0)
        case .status:
            ascending(Self.statusRank(first.status), Self.statusRank(second.status))
        case .firstTry:
            ascending(second.firstTry, first.firstTry)
        case .lastTry:
            ascending(second.lastTry, first.lastTry)
        }
    }

    private func ascending<Value: Comparable>(_ first: Value, _ second: Value) -> ComparisonResult {
        if first < second { return .orderedAscending }
        if first > second { return .orderedDescending }
        return .orderedSame
    }

    private static func statusRank(_ status: DownloadStatus) -> Int {
        switch status {
        case .complete: 1
        case .stopped: 2
        case .error: 3
        case .downloading: 4
        case .waiting: 5
        default: 6
        }
    }
}
