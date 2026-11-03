import Testing
import SwiftpolisDomain

@Suite("Formatting")
struct FormattingTests {
    // Expected values worked out from Persepolis's humanReadableSize: whole numbers up to MiB, and
    // two decimals from GiB.
    @Test("sizes", arguments: [
        (Int64(0), "0 B"),
        (Int64(512), "512 B"),
        (Int64(1_024), "1 KiB"),
        (Int64(1_536), "2 KiB"),
        (Int64(5 * 1_048_576), "5 MiB"),
        (Int64(5 * 1_048_576 + 524_288), "6 MiB"),
        (Int64(2 * 1_073_741_824), "2.0 GiB"),
        (Int64(1_610_612_736), "1.5 GiB"),
        (Int64(1_099_511_627_776), "1.0 TiB"),
    ])
    func sizes(bytes: Int64, text: String) {
        #expect(ByteFormat.size(bytes) == text)
    }

    @Test("speeds show one decimal in MiB", arguments: [
        (0.0, "0 B/s"),
        (512.0, "512 B/s"),
        (2_048.0, "2 KiB/s"),
        (3_670_016.0, "3.5 MiB/s"),
    ])
    func speeds(bytesPerSecond: Double, text: String) {
        #expect(ByteFormat.speed(bytesPerSecond) == text)
    }

    @Test("time remaining", arguments: [
        (0.0, "0s"),
        (45.9, "45s"),
        (60.0, "1m"),
        (179.0, "2m"),
        (3_600.0, "1h 0m"),
        (3_725.0, "1h 2m"),
    ])
    func remaining(seconds: Double, text: String) {
        #expect(DurationFormat.remaining(seconds: seconds) == text)
    }
}
