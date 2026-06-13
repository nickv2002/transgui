import Foundation

/// Shared display formatters for sizes, speeds, ETA, and ratios.
enum Formatters {
    private static func byteFormatter() -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f
    }

    static func size(_ bytes: Int64) -> String {
        byteFormatter().string(fromByteCount: max(0, bytes))
    }

    /// A transfer rate; blank when zero so idle rows stay quiet.
    static func speed(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "" }
        return byteFormatter().string(fromByteCount: bytesPerSec) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    static func ratio(_ value: Double) -> String {
        guard value >= 0 else { return "∞" }
        return String(format: "%.2f", value)
    }

    /// Transmission ETA: -1 unknown, -2 not applicable, else seconds remaining.
    static func eta(_ seconds: Int) -> String {
        switch seconds {
        case ..<(-1): return ""
        case -1: return "∞"
        default:
            if seconds == 0 { return "Done" }
            let d = seconds / 86400
            let h = (seconds % 86400) / 3600
            let m = (seconds % 3600) / 60
            let s = seconds % 60
            if d > 0 { return "\(d)d \(h)h" }
            if h > 0 { return "\(h)h \(m)m" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        }
    }

    static func date(_ epoch: Double) -> String {
        guard epoch > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: epoch)
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
    }

    /// Full date + time, used in the detail pane.
    static func dateTime(_ epoch: Double) -> String {
        guard epoch > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: epoch)
        return DateFormatter.localizedString(from: d, dateStyle: .long, timeStyle: .medium)
    }
}
