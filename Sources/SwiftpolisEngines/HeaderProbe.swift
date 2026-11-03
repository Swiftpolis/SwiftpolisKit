import Foundation
import SwiftpolisDomain

/// What a HEAD request says about a file.
struct HeaderProbe {
    var fileSize: Int64?
    var etag: String?
    var supportsRanges = false
    var contentDisposition: String?

    /// `onSession` receives the session as soon as it exists, so the caller can cancel it.
    static func fetch(
        requests: RequestFactory,
        onSession: (URLSession) -> Void = { _ in }
    ) async throws -> HeaderProbe {
        let delegate = RequestPolicyDelegate(requests: requests)
        let session = requests.makeSession(delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        onSession(session)

        let (_, response) = try await session.data(for: requests.make(method: "HEAD"))
        guard let response = response as? HTTPURLResponse, response.statusCode < 400 else {
            // Some servers refuse HEAD. The GET decides whether the file is really there.
            return HeaderProbe()
        }
        return HeaderProbe(
            fileSize: response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) },
            etag: response.value(forHTTPHeaderField: "ETag"),
            supportsRanges: response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes",
            contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition")
        )
    }
}

/// The lightweight request that learns a Download's file name and size without fetching it.
public enum Spider {
    public struct Findings: Equatable, Sendable {
        public var fileName: String?
        public var totalBytes: Int64?

        public init(fileName: String? = nil, totalBytes: Int64? = nil) {
            self.fileName = fileName
            self.totalBytes = totalBytes
        }
    }

    /// Failures are ignored, as in Persepolis: the name and size simply stay unknown.
    public static func look(
        at request: DownloadRequest,
        secrets: DownloadSecrets,
        settings: EngineSettings
    ) async -> Findings {
        let requests = RequestFactory(request: request, secrets: secrets, settings: settings)
        guard let probe = try? await HeaderProbe.fetch(requests: requests) else { return Findings() }
        return Findings(
            fileName: FileNaming.resolve(
                custom: request.customFileName,
                contentDisposition: probe.contentDisposition,
                link: request.link
            ),
            totalBytes: probe.fileSize
        )
    }
}
