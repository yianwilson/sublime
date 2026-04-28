import SwiftUI
import Charts

struct PortfolioComparisonView: View {
    let portfolios: [NamedPortfolio]
    @EnvironmentObject var portfoliosVM: PortfoliosViewModel

    // For each portfolio: (name, transactionCount, net cost basis)
    var summaries: [(name: String, transactions: Int, costBasis: Double)] {
        portfolios.map { p in
            let bought = p.transactions
                .filter { $0.type == .buy || $0.type == .dividend }
                .reduce(0.0) { $0 + $1.price * $1.quantity }
            let sold = p.transactions
                .filter { $0.type == .sell }
                .reduce(0.0) { $0 + $1.price * $1.quantity }
            return (p.name, p.transactions.count, max(0, bought - sold))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Summary cards
                    ForEach(summaries, id: \.name) { summary in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.name)
                                    .font(.headline)
                                Text("\(summary.transactions) transactions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(summary.costBasis,
                                     format: .currency(code: "AUD").presentation(.narrow))
                                    .font(.title3.bold())
                                Text("cost basis")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }

                    // Bar chart comparing cost bases
                    if !summaries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cost Basis Comparison")
                                .font(.headline)
                            Chart(summaries, id: \.name) { s in
                                BarMark(
                                    x: .value("Cost Basis", s.costBasis),
                                    y: .value("Portfolio", s.name)
                                )
                                .foregroundStyle(by: .value("Portfolio", s.name))
                            }
                            .frame(height: CGFloat(summaries.count) * 60 + 40)
                            .chartXAxis {
                                AxisMarks { value in
                                    AxisValueLabel {
                                        if let v = value.as(Double.self) {
                                            Text(v, format: .currency(code: "AUD").presentation(.narrow))
                                                .font(.caption2)
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }

                    // Prompt to add a second portfolio when there is only one
                    if portfolios.count < 2 {
                        ContentUnavailableView(
                            "Add Another Portfolio",
                            systemImage: "chart.bar.doc.horizontal",
                            description: Text("Create a second portfolio to compare performance")
                        )
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Compare Portfolios")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
