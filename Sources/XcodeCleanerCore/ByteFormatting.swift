import Foundation

public enum ByteFormatting {
    private static let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]

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
        if value.rounded() >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let decimals = value < 10 ? 1 : 0
        let number = String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
        return "\(sign)\(number) \(units[unitIndex])"
    }
}
