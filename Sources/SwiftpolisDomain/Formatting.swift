/// Display text in Persepolis's style, using binary units.
public enum ByteFormat {
    public static func size(_ bytes: Int64) -> String {
        format(Double(bytes), isSpeed: false)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        format(max(0, bytesPerSecond), isSpeed: true) + "/s"
    }

    private static func format(_ value: Double, isSpeed: Bool) -> String {
        guard value >= 1_024 else { return "\(Int(value)) B" }

        let labels = ["KiB", "MiB", "GiB", "TiB"]
        var size = value
        var index = -1
        while size >= 1_024, index < labels.count - 1 {
            size /= 1_024
            index += 1
        }

        if index > 1 {
            return "\(rounded(size, places: 2)) \(labels[index])"
        }
        if index == 1, isSpeed {
            return "\(rounded(size, places: 1)) \(labels[index])"
        }
        return "\(Int(size.rounded(.toNearestOrEven))) \(labels[index])"
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = places == 1 ? 10.0 : 100.0
        return (value * scale).rounded() / scale
    }
}

public enum DurationFormat {
    /// A running time, as `1:02:03` or `2:03`.
    public static func clock(seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let (hours, minutes, rest) = (total / 3_600, total % 3_600 / 60, total % 60)
        let tail = String(format: "%02d", rest)
        if hours > 0 { return "\(hours):" + String(format: "%02d", minutes) + ":" + tail }
        return "\(minutes):" + tail
    }

    public static func remaining(seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let minutes = total / 60
        if minutes == 0 { return "\(total)s" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
