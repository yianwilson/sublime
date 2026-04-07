import SwiftUI

struct TradeDetailView: View {
    let trade: Trade
    @EnvironmentObject private var vm: PortfolioViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Trade Summary") {
                    metricRow("Symbol", trade.symbol)
                    metricRow("Type", trade.assetType.rawValue)
                    metricRow("Quantity", trade.quantity.asQuantity())
                    metricRow("Holding Period", "\(trade.holdingDays) day\(trade.holdingDays == 1 ? "" : "s")")
                }

                Section("Entry") {
                    metricRow("Date", trade.entryDate.formatted(date: .abbreviated, time: .omitted))
                    metricRow("Price", trade.entryPrice.asCurrency())
                    metricRow("Total Cost", (trade.quantity * trade.entryPrice).asCurrency())
                }

                Section("Exit") {
                    metricRow("Date", trade.exitDate.formatted(date: .abbreviated, time: .omitted))
                    metricRow("Price", trade.exitPrice.asCurrency())
                    metricRow("Total Proceeds", (trade.quantity * trade.exitPrice).asCurrency())
                }

                Section("Result") {
                    if trade.fee > 0 {
                        metricRow("Fees", trade.fee.asCurrency())
                    }
                    metricRow(
                        "P&L",
                        (trade.pnl * vm.audPerUSD).asChange(code: vm.baseCurrencyCode),
                        accent: trade.pnl >= 0 ? .green : .red
                    )
                    metricRow(
                        "Return",
                        trade.pnlPercent.asPercent(),
                        accent: trade.pnl >= 0 ? .green : .red
                    )
                    metricRow(
                        "Annualised",
                        annualisedReturn.asPercent(),
                        accent: annualisedReturn >= 0 ? .green : .red
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Trade Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var annualisedReturn: Double {
        guard trade.holdingDays > 0, trade.entryPrice > 0 else { return 0 }
        let fraction = Double(trade.holdingDays) / 365.0
        return (pow(1 + trade.pnlPercent / 100, 1 / fraction) - 1) * 100
    }

    private func metricRow(_ label: String, _ value: String, accent: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(accent).fontWeight(.medium)
        }
    }
}
