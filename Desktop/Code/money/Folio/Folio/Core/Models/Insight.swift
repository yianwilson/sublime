import Foundation

struct Insight: Identifiable, Equatable {
    enum Severity: String {
        case info
        case warning
        case critical
    }

    let id = UUID()
    let title: String
    let description: String
    let severity: Severity
}
