/// What a Category is. Scheduled Downloads is an ordinary Queue, except that it can't be removed.
public enum CategoryKind: String, Sendable {
    case allDownloads
    case singleDownloads
    case queue

    public static let allDownloadsName = "All Downloads"
    public static let singleDownloadsName = "Single Downloads"
    public static let scheduledDownloadsName = "Scheduled Downloads"

    /// The Categories that always exist, in side panel order.
    public static let builtInNames = [allDownloadsName, singleDownloadsName, scheduledDownloadsName]

    public init(categoryName: String) {
        switch categoryName {
        case Self.allDownloadsName: self = .allDownloads
        case Self.singleDownloadsName: self = .singleDownloads
        default: self = .queue
        }
    }

    public static func canRemove(categoryNamed name: String) -> Bool {
        !builtInNames.contains(name)
    }

    public static func validateNewQueueName(_ name: String, existing: [String]) throws(QueueNameError) {
        if name.isEmpty { throw .empty }
        if existing.contains(name) { throw .alreadyExists }
    }
}

public enum QueueNameError: Error, Equatable, Sendable {
    case empty
    case alreadyExists
}
