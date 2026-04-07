import SwiftUI

struct AddAssetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var portfolioVM: PortfolioViewModel
    @StateObject private var vm = AssetViewModel()

    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                detailsSection
                transactionSection
            }
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let tx = vm.buildTransaction() {
                            portfolioVM.addTransaction(tx)
                            dismiss()
                        }
                    }
                    .disabled(!vm.isValid)
                }
            }
        }
    }

    // MARK: - Search Section

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search symbol or name...", text: $searchQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onChange(of: searchQuery) { _, query in
                        vm.search(query: query)
                    }
                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if !vm.searchResults.isEmpty {
                ForEach(vm.searchResults) { result in
                    Button {
                        vm.selectResult(result)
                        searchQuery = result.symbol
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: result.assetType.icon)
                                .foregroundStyle(result.assetType.color)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.symbol).bold()
                                Text(result.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let metadata = metadataText(for: result) {
                                    Text(metadata)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(result.assetType.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(result.assetType.color.opacity(0.15), in: Capsule())
                                    .foregroundStyle(result.assetType.color)
                                if let badge = badgeText(for: result) {
                                    Text(badge)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Search")
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        Section("Asset Details") {
            HStack {
                Text("Symbol")
                Spacer()
                TextField("e.g. AAPL", text: $vm.symbol)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            HStack {
                Text("Name")
                Spacer()
                TextField("e.g. Apple Inc.", text: $vm.name)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Type", selection: $vm.assetType) {
                ForEach(AssetType.allCases) { type in
                    Label(type.rawValue, systemImage: type.icon).tag(type)
                }
            }
        }
    }

    // MARK: - Transaction Section

    private var transactionSection: some View {
        Section("Transaction") {
            Picker("Action", selection: $vm.transactionType) {
                ForEach(TransactionType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Quantity")
                Spacer()
                TextField("0", text: $vm.quantity)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            }
            HStack {
                Text("Price (USD)")
                Spacer()
                TextField("0.00", text: $vm.price)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            }
            HStack {
                Text("Fee (USD)")
                Spacer()
                TextField("0.00", text: $vm.fee)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            }
            DatePicker("Date", selection: $vm.date, displayedComponents: [.date])

            if let qty = Double(vm.quantity), let px = Double(vm.price), qty > 0, px > 0 {
                HStack {
                    Text("Total")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text((qty * px).asCurrency())
                        .fontWeight(.medium)
                }
            }
        }
    }

    private func badgeText(for result: AssetSearchResult) -> String? {
        switch result.assetType {
        case .crypto:
            guard let rank = result.marketRank else { return nil }
            return "Rank #\(rank)"
        case .stock, .etf:
            return result.market
        }
    }

    private func metadataText(for result: AssetSearchResult) -> String? {
        nil
    }
}
