import SwiftUI

struct TransactionHistoryView: View {
    @EnvironmentObject private var vm: PortfolioViewModel
    @Environment(\.dismiss) private var dismiss

    private var sortedTransactions: [Transaction] {
        vm.transactions.sorted { $0.date > $1.date }
    }

    private var groupedTransactions: [(String, [Transaction])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let grouped = Dictionary(grouping: sortedTransactions) {
            formatter.string(from: $0.date)
        }
        // Sort groups by most recent month
        return grouped
            .sorted { a, b in
                let t1 = a.value.first?.date ?? .distantPast
                let t2 = b.value.first?.date ?? .distantPast
                return t1 > t2
            }
    }

    var body: some View {
        List {
            ForEach(groupedTransactions, id: \.0) { month, txs in
                Section(month) {
                    ForEach(txs) { tx in
                        transactionRow(tx)
                    }
                    .onDelete { offsets in
                        offsets.forEach { idx in
                            vm.deleteTransaction(txs[idx])
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "tray",
                    description: Text("Add a buy or sell transaction to get started.")
                )
            }
        }
    }

    private func transactionRow(_ tx: Transaction) -> some View {
        HStack(spacing: 12) {
            // Type badge
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tx.type == .buy ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(tx.type == .buy ? "BUY" : "SELL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tx.type == .buy ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(tx.symbol)
                    .font(.subheadline.weight(.semibold))
                Text(tx.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(tx.quantity.asQuantity()) @ \(tx.price.asCurrency())")
                    .font(.subheadline.weight(.medium))
                let total = tx.quantity * tx.price
                Text(total.asCurrency())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if tx.fee > 0 {
                    Text("fee: \(tx.fee.asCurrency())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
