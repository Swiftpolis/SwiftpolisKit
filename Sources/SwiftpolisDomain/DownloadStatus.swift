/// Where a Download is in its life. Raw values match what Persepolis stores.
public enum DownloadStatus: String, CaseIterable, Sendable {
    case waiting
    case scheduled
    case creatingDownloadFile = "creating download file"
    case downloading
    case paused
    case stopped
    case error
    case complete

    /// The status a Download has after the app launches. Nothing resumes by itself.
    public var afterLaunch: DownloadStatus {
        switch self {
        case .complete, .error: self
        default: .stopped
        }
    }

    public var canChangeCategory: Bool {
        switch self {
        case .stopped, .error, .complete: true
        default: false
        }
    }
}
