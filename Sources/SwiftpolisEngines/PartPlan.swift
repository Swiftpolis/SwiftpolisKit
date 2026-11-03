/// A byte range of a file, tracked separately so it can be resumed.
struct Part: Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case downloading
        case stopped
        case error
        case complete
    }

    var start: Int64
    /// `nil` when the file's size is unknown.
    var length: Int64?
    var downloaded: Int64 = 0
    var status = Status.pending
    var retryCount = -1
}

struct PartPlan: Equatable, Sendable {
    var parts: [Part]
    var connections: Int

    static let maximumParts = 64
    private static let mebibyte: Int64 = 1_048_576

    /// Splits a file into at most 64 Parts of at least 1 MiB.
    ///
    /// Without a known size or range support there is only one way to fetch a file, so that is
    /// one Part and one Connection.
    static func make(fileSize: Int64?, supportsRanges: Bool, connections requested: Int) -> PartPlan {
        guard let fileSize, supportsRanges else {
            return PartPlan(parts: [Part(start: 0, length: fileSize)], connections: 1)
        }

        let evenPartSize = fileSize / Int64(maximumParts)
        let partSize: Int64
        let count: Int
        if evenPartSize >= mebibyte {
            partSize = evenPartSize
            count = maximumParts
        } else {
            partSize = mebibyte
            count = max(1, Int((fileSize - 1) / mebibyte) + 1)
        }

        let parts = (0..<count).map { index in
            let start = Int64(index) * partSize
            let end = index == count - 1 ? fileSize : start + partSize
            return Part(start: start, length: end - start)
        }
        return PartPlan(parts: parts, connections: min(max(1, requested), count))
    }
}
