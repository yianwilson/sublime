import Foundation
import Combine

@MainActor
final class PortfoliosViewModel: ObservableObject {

    @Published private(set) var portfolios: [NamedPortfolio] = []
    @Published var activePortfolioId: UUID {
        didSet { UserDefaults.standard.set(activePortfolioId.uuidString, forKey: "activePortfolioId") }
    }

    var activePortfolio: NamedPortfolio? {
        portfolios.first { $0.id == activePortfolioId }
    }

    private let persistence: PersistenceService

    init(persistence: PersistenceService = PersistenceService()) {
        self.persistence = persistence
        let loaded = persistence.loadNamedPortfolios()
        self.portfolios = loaded

        // Restore last active portfolio or default to first
        if let savedId = UserDefaults.standard.string(forKey: "activePortfolioId"),
           let uuid = UUID(uuidString: savedId),
           loaded.contains(where: { $0.id == uuid }) {
            self.activePortfolioId = uuid
        } else {
            self.activePortfolioId = loaded.first?.id ?? UUID()
        }
    }

    func createPortfolio(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "Portfolio \(portfolios.count + 1)" : trimmed
        let p = NamedPortfolio(name: resolvedName)
        portfolios.append(p)
        persistence.saveNamedPortfolios(portfolios)
        activePortfolioId = p.id
    }

    func rename(_ portfolio: NamedPortfolio, to name: String) {
        guard let idx = portfolios.firstIndex(where: { $0.id == portfolio.id }) else { return }
        portfolios[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persistence.saveNamedPortfolios(portfolios)
    }

    func delete(_ portfolio: NamedPortfolio) {
        guard portfolios.count > 1 else { return }  // always keep at least one
        portfolios.removeAll { $0.id == portfolio.id }
        persistence.saveNamedPortfolios(portfolios)
        if activePortfolioId == portfolio.id {
            activePortfolioId = portfolios.first!.id
        }
    }

    /// Called by PortfolioViewModel when its transactions change
    func updateTransactions(_ transactions: [Transaction], for portfolioId: UUID) {
        guard let idx = portfolios.firstIndex(where: { $0.id == portfolioId }) else { return }
        portfolios[idx].transactions = transactions
        persistence.saveNamedPortfolios(portfolios)
    }
}
