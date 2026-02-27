import Foundation

extension DailyUsage {
    var formattedDate: String {
        let components = date.split(separator: "-")
        guard components.count == 3 else { return date }
        return "\(components[1])/\(components[2])"
    }
}

extension UsageTotals {
    func formattedTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000.0)
        }
        return "\(tokens)"
    }

    func formattedCost(_ cost: Double) -> String {
        if cost == 0 {
            return "$0.00"
        }
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}
