import Foundation

public enum ByteFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    public static func string(_ bytes: Int64) -> String {
        var value = Double(bytes.magnitude)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let sign = bytes < 0 ? "-" : ""
        if unitIndex == 0 {
            return "\(sign)\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%@%.2f %@", sign, value, units[unitIndex])
    }
}
