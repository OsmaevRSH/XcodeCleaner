import Foundation

/// Picks the noun form a Russian numeral needs: «1 маунт», «2 маунта», «5 маунтов».
enum RussianPlural {
    static func form(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let absolute = abs(count)
        if absolute % 100 >= 11, absolute % 100 <= 14 {
            return many
        }
        switch absolute % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    static func mounts(_ count: Int) -> String {
        "\(count) \(form(count, "маунт", "маунта", "маунтов"))"
    }

    static func devices(_ count: Int) -> String {
        "\(count) \(form(count, "устройство", "устройства", "устройств"))"
    }

    /// The genitive the «старше …» construction takes: «старше 1 дня», «старше 30 дней».
    static func daysAfterOlderThan(_ count: Int) -> String {
        "\(count) \(form(count, "дня", "дней", "дней"))"
    }
}
