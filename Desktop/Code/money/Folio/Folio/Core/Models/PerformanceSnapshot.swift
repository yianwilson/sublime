import Foundation

struct PerformanceSnapshot: Identifiable, Codable, Equatable {
    var id: Date { date }
    let date: Date
    let totalValue: Double
}
