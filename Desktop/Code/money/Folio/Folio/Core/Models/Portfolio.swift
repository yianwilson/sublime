import Foundation

/// Used for JSON encoding/decoding of a single portfolio's transactions (backward-compatible).
struct Portfolio: Codable {
    var transactions: [Transaction] = []
}

/// A named portfolio entry in the multi-portfolio store.
struct NamedPortfolio: Identifiable, Codable {
    let id: UUID
    var name: String
    var transactions: [Transaction]
    let createdAt: Date

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.transactions = []
        self.createdAt = Date()
    }
}
