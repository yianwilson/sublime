import SwiftUI

enum AssetType: String, Codable, CaseIterable, Identifiable {
    case stock = "Stock"
    case etf = "ETF"
    case crypto = "Crypto"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .stock:  return "chart.line.uptrend.xyaxis"
        case .etf:    return "building.columns"
        case .crypto: return "bitcoinsign.circle"
        }
    }

    var color: Color {
        switch self {
        case .stock:  return .blue
        case .etf:    return .green
        case .crypto: return .orange
        }
    }
}
