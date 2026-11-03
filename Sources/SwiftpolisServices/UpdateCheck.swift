import Foundation

/// A version like `1.2.0`, compared number by number, so `1.10` is newer than `1.9`.
public struct AppVersion: Comparable, Sendable {
    private let numbers: [Int]

    /// Accepts a release tag too, such as `v1.2.0`.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        numbers = parts.compactMap { $0 }
    }

    public static func == (left: AppVersion, right: AppVersion) -> Bool {
        !(left < right) && !(right < left)
    }

    public static func < (left: AppVersion, right: AppVersion) -> Bool {
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let (first, second) = (left.number(at: index), right.number(at: index))
            if first != second { return first < second }
        }
        return false
    }

    private func number(at index: Int) -> Int {
        index < numbers.count ? numbers[index] : 0
    }
}

/// A published version of the app.
public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let page: URL

    public init(version: String, notes: String, page: URL) {
        self.version = version
        self.notes = notes
        self.page = page
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    /// The repository exists but hasn't published anything yet, or can't be found.
    case noReleases
    case available(AppRelease)
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case refused(status: Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .refused(let status): "GitHub answered with status \(status). Try again later."
        case .unreadable: "GitHub's answer couldn't be read."
        }
    }
}

/// Asks GitHub for the latest release. It only says what's there: the person downloads it themselves.
public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Release: Decodable {
        var tagName: String
        var body: String?
        var htmlUrl: URL
    }

    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let endpoint: URL
    private let fetch: Fetch

    /// `repository` is `owner/name`.
    public init(
        repository: String,
        apiBase: URL = URL(string: "https://api.github.com")!,
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }
    ) {
        endpoint = apiBase.appending(path: "repos/\(repository)/releases/latest")
        self.fetch = fetch
    }

    public func check(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Swiftpolis/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .noReleases }
        guard status == 200 else { throw UpdateCheckError.refused(status: status) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data),
              let latest = AppVersion(release.tagName),
              let current = AppVersion(currentVersion),
              // The app opens this page, so it has to be GitHub's.
              release.htmlUrl.scheme == "https", release.htmlUrl.host() == "github.com"
        else { throw UpdateCheckError.unreadable }

        guard latest > current else { return .upToDate }
        return .available(AppRelease(
            version: release.tagName,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            page: release.htmlUrl
        ))
    }

    /// The automatic check runs at most once a day.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }
}
