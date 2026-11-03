import Foundation

enum RequestText {
    struct Cookie: Equatable {
        var domain: String
        var path: String
        var name: String
        var value: String
    }

    /// Parses the free-form header text a user or browser supplies.
    static func headers(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("GET") || line.hasPrefix("POST") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    /// Parses a Netscape `cookies.txt` file. Expiry and the secure flag are ignored, as in Persepolis.
    static func cookies(from text: String) -> [Cookie] {
        let httpOnlyPrefix = "#HttpOnly_"
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 7 else { return nil }
            var domain = fields[0]
            if domain.hasPrefix(httpOnlyPrefix) {
                domain.removeFirst(httpOnlyPrefix.count)
            } else if domain.hasPrefix("#") {
                return nil
            }
            return Cookie(domain: domain, path: fields[2], name: fields[5], value: fields[6])
        }
    }
}

/// The retries made within one attempt at a Part. Persepolis gets these from urllib3's `Retry`.
enum RetryPolicy {
    private static let maximumDelay: TimeInterval = 120

    static func isRetryable(status: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(status)
    }

    /// The wait after the given failure, counting from 1. The first retry is immediate.
    static func delay(afterFailure failure: Int, retryWait: TimeInterval) -> TimeInterval {
        guard failure > 1 else { return 0 }
        return min(maximumDelay, retryWait * pow(2, Double(failure - 1)))
    }
}

enum SpeedDial {
    static let maximum = 10

    /// Persepolis's formula: the seconds each Connection waits after every chunk. Because the wait
    /// grows with the Connections, the dial acts as a limit on the Download's total speed.
    static func delayPerChunk(dial: Int, connections: Int) -> TimeInterval {
        TimeInterval(maximum - min(max(0, dial), maximum)) * 0.005 * TimeInterval(connections)
    }
}
