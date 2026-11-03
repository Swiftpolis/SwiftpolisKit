import Foundation

/// The `<file name>.persepolis` file beside a partial download.
///
/// The format matches Persepolis's, including its misspelt key, so a download started in
/// either app can be resumed by the other.
struct ControlFile: Equatable, Sendable {
    static let fileExtension = "persepolis"

    var etag: String?
    var fileName: String
    var fileSize: Int64?
    var parts: [Part]

    enum DecodingError: Error {
        case malformed
    }

    /// Reads a control file. Unfinished Parts come back pending, ready to be resumed.
    static func decode(_ data: Data) throws -> ControlFile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["number_of_parts"] as? Int,
              let entries = json["download_infromation_list"] as? [[Any]],
              count >= 0, count <= entries.count
        else { throw DecodingError.malformed }

        let fileSize = (json["file_size"] as? NSNumber)?.int64Value
        var starts: [Int64] = []
        for entry in entries.prefix(count) {
            guard let start = (entry.first as? NSNumber)?.int64Value else {
                throw DecodingError.malformed
            }
            starts.append(start)
        }

        var parts: [Part] = []
        for (index, start) in starts.enumerated() {
            let entry = entries[index]
            guard entry.count == 4,
                  let downloaded = (entry[1] as? NSNumber)?.int64Value,
                  let status = entry[2] as? String
            else { throw DecodingError.malformed }

            let end = index + 1 < starts.count ? starts[index + 1] : fileSize
            var part = Part(start: start, length: end.map { $0 - start }, downloaded: downloaded)
            if status == Part.Status.complete.rawValue {
                part.status = .complete
                part.retryCount = (entry[3] as? Int) ?? -1
            }
            parts.append(part)
        }

        return ControlFile(
            etag: json["ETag"] as? String,
            fileName: (json["file_name"] as? String) ?? "",
            fileSize: fileSize,
            parts: parts
        )
    }

    func encoded() throws -> Data {
        var entries: [[Any]] = parts.map { part in
            [part.start, part.downloaded, part.status.rawValue, part.retryCount]
        }
        // Persepolis always writes 64 entries, marking the unused ones complete.
        let unused: [Any] = [max(0, (fileSize ?? 1) - 1), 0, Part.Status.complete.rawValue, -1]
        entries += Array(repeating: unused, count: max(0, PartPlan.maximumParts - entries.count))

        let json: [String: Any] = [
            "ETag": etag ?? NSNull(),
            "file_name": fileName,
            "file_size": fileSize ?? NSNull(),
            "number_of_parts": parts.count,
            "download_infromation_list": entries,
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}

/// What to do when a Download starts, given any control file already beside it.
enum ResumeDecision: Equatable, Sendable {
    case resume
    case startFresh
    case renameAndStartFresh

    static func decide(
        control: ControlFile?,
        etag: String?,
        fileSize: Int64?,
        supportsRanges: Bool,
        fileExists: Bool
    ) -> ResumeDecision {
        guard let control else { return .startFresh }
        guard isSameFile(control: control, etag: etag, fileSize: fileSize) else {
            return fileExists ? .renameAndStartFresh : .startFresh
        }
        return supportsRanges && fileExists ? .resume : .startFresh
    }

    /// ETags are compared only if both sides have one. Otherwise two missing ETags would look
    /// equal and hide a changed file.
    private static func isSameFile(control: ControlFile, etag: String?, fileSize: Int64?) -> Bool {
        if let old = control.etag, let new = etag { return old == new }
        if let old = control.fileSize, let new = fileSize { return old == new }
        return false
    }
}
