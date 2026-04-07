import Foundation

final class PortfolioInsightsService {
    func generateInsights(holdings: [Holding], quotes: [String: AssetQuote]) -> [Insight] {
        guard !holdings.isEmpty else {
            return [
                Insight(
                    title: "No portfolio data yet",
                    description: "Add or import assets to generate allocation and performance insights.",
                    severity: .info
                )
            ]
        }

        let totalValue = holdings.reduce(0.0) { partial, holding in
            partial + holding.currentValue(price: quotes[holding.symbol]?.currentPrice ?? holding.averageCostBasis)
        }

        guard totalValue > 0 else {
            return [
                Insight(
                    title: "Waiting for market data",
                    description: "Refresh prices to unlock concentration, allocation, and mover insights.",
                    severity: .info
                )
            ]
        }

        var insights: [Insight] = []
        let holdingAllocations = holdings.map { holding in
            let value = holding.currentValue(price: quotes[holding.symbol]?.currentPrice ?? holding.averageCostBasis)
            return (holding: holding, percent: value / totalValue * 100)
        }.sorted { $0.percent > $1.percent }

        if let largestPosition = holdingAllocations.first {
            let severity: Insight.Severity = largestPosition.percent > 50 ? .critical : largestPosition.percent > 30 ? .warning : .info
            let title = severity == .info
                ? "Largest position is \(largestPosition.holding.symbol) (\(formatPercent(largestPosition.percent)))"
                : "High concentration in \(largestPosition.holding.symbol) (\(formatPercent(largestPosition.percent)))"
            let description = "Single-asset exposure this high can dominate portfolio performance."
            insights.append(Insight(title: title, description: description, severity: severity))
        }

        let groupedByType = Dictionary(grouping: holdings, by: \.assetType)
        let typeAllocations = AssetType.allCases.compactMap { type -> (AssetType, Double)? in
            let holdingsForType = groupedByType[type] ?? []
            guard !holdingsForType.isEmpty else { return nil }
            let value = holdingsForType.reduce(0.0) { partial, holding in
                partial + holding.currentValue(price: quotes[holding.symbol]?.currentPrice ?? holding.averageCostBasis)
            }
            return (type, value / totalValue * 100)
        }.sorted { $0.1 > $1.1 }

        if let dominantType = typeAllocations.first {
            let severity: Insight.Severity = dominantType.1 > 85 ? .critical : dominantType.1 > 70 ? .warning : .info
            insights.append(
                Insight(
                    title: "\(dominantType.0.rawValue) exposure is \(formatPercent(dominantType.1))",
                    description: "Track whether this asset class balance still matches your intended strategy.",
                    severity: severity
                )
            )
        }

        let movers = holdings.map { holding in
            (holding: holding, pnlPercent: holding.unrealisedPnLPercent(price: quotes[holding.symbol]?.currentPrice ?? holding.averageCostBasis))
        }
        .sorted { $0.pnlPercent > $1.pnlPercent }

        if let best = movers.first {
            insights.append(
                Insight(
                    title: "Top mover: \(best.holding.symbol) \(best.pnlPercent.asPercent())",
                    description: "Best unrealised return in the portfolio based on average buy price.",
                    severity: .info
                )
            )
        }

        if let worst = movers.last, worst.holding.id != movers.first?.holding.id {
            insights.append(
                Insight(
                    title: "Weakest holding: \(worst.holding.symbol) \(worst.pnlPercent.asPercent())",
                    description: "Lowest unrealised return in the portfolio right now.",
                    severity: worst.pnlPercent < -20 ? .warning : .info
                )
            )
        }

        let dailyDrivers = holdings.compactMap { holding -> (Holding, Double)? in
            guard let previousClose = quotes[holding.symbol]?.previousClose else { return nil }
            let currentPrice = quotes[holding.symbol]?.currentPrice ?? holding.averageCostBasis
            let contribution = (currentPrice - previousClose) * holding.quantity
            return (holding, contribution)
        }
        .sorted { abs($0.1) > abs($1.1) }

        if let driver = dailyDrivers.first {
            insights.append(
                Insight(
                    title: "Daily driver: \(driver.0.symbol)",
                    description: "This holding is contributing the most to today's gain or loss.",
                    severity: abs(driver.1) > totalValue * 0.05 ? .warning : .info
                )
            )
        }

        return insights
    }

    private func formatPercent(_ value: Double) -> String {
        "\(String(format: "%.1f", value))%"
    }
}
