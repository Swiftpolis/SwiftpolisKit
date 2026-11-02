/// The 16-character lowercase hex identifier of a Download.
public struct GID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init?(rawValue: String) {
        let isValid = rawValue.utf8.count == 16 && rawValue.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
        guard isValid else { return nil }
        self.rawValue = rawValue
    }

    /// Returns a new GID that isn't in `existing`.
    ///
    /// The range matches Persepolis's: the lower bound guarantees 16 hex digits.
    public static func generate(
        avoiding existing: Set<GID>,
        using generator: inout some RandomNumberGenerator
    ) -> GID {
        while true {
            let value = UInt64.random(in: 0x1000_0000_0000_0000...UInt64.max, using: &generator)
            let gid = GID(unchecked: String(value, radix: 16))
            if !existing.contains(gid) { return gid }
        }
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}
