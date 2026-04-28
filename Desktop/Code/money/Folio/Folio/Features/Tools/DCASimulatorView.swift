import SwiftUI
import Charts

struct DCASimulatorView: View {
    @State private var symbol = ""
    @State private var monthlyAmount: Double = 500
    @State private var startDate = Calendar.current.date(byAdding: .year, value: -3, to: Date()) ?? Date()
    @State private var assetType: AssetType = .stock
    @State private var results: DCAResults? = nil
    @State private var isCalculating = false
    @State private var errorMessage: String? = nil

    private let historicalService = HistoricalPriceService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Asset") {
                    TextField("Symbol (e.g. AAPL, BTC)", text: $symbol)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)

                    Picker("Asset Type", selection: $assetType) {
                        Text("Stock").tag(AssetType.stock)
                        Text("ETF").tag(AssetType.etf)
                        Text("Crypto").tag(AssetType.crypto)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Parameters") {
                    HStack {
                        Text("Monthly Amount")
                        Spacer()
                        TextField("Amount", value: $monthlyAmount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    DatePicker(
                        "Start Date",
                        selection: $startDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                }

                Section {
                    Button("Calculate") {
                        Task { await calculate() }
                    }
                    .disabled(symbol.trimmingCharacters(in: .whitespaces).isEmpty || isCalculating)
                }

                if isCalculating {
                    Section {
                        ProgressView("Fetching price history...")
                            .frame(maxWidth: .infinity)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if let r = results {
                    Section("Results") {
                        LabeledContent("Total Invested", value: r.totalInvested, format: .currency(code: "USD"))
                        LabeledContent("Current Value", value: r.currentValue, format: .currency(code: "USD"))
                        LabeledContent("Total Return", value: r.totalReturn, format: .currency(code: "USD"))
                        LabeledContent("Return %") {
                            Text(String(format: "%.1f%%", r.returnPercent))
                                .foregroundStyle(r.returnPercent >= 0 ? .green : .red)
                        }
                        LabeledContent(
                            "Total Shares",
                            value: r.totalShares,
                            format: .number.precision(.fractionLength(4))
                        )
                    }

                    if !r.series.isEmpty {
                        Section("Portfolio Growth") {
                            Chart(r.series, id: \.date) { point in
                                LineMark(
                                    x: .value("Date", point.date),
                                    y: .value("Value", point.value)
                                )
                                .foregroundStyle(Color.accentColor)

                                AreaMark(
                                    x: .value("Date", point.date),
                                    y: .value("Value", point.value)
                                )
                                .foregroundStyle(Color.accentColor.opacity(0.15))
                            }
                            .frame(height: 180)
                            .chartXAxis(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                }
            }
            .navigationTitle("DCA Simulator")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Calculation

    private func calculate() async {
        isCalculating = true
        errorMessage = nil
        results = nil

        let uppercasedSymbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        let lookup = PriceLookup(symbol: uppercasedSymbol, assetType: assetType, coinGeckoId: "")
        let history = await historicalService.fetchPriceHistory(for: [lookup], from: startDate)

        guard let prices = history[uppercasedSymbol], !prices.isEmpty else {
            errorMessage = "Could not fetch price history for \(uppercasedSymbol). Check the symbol and try again."
            isCalculating = false
            return
        }

        // Sort prices ascending
        let sortedPrices = prices.sorted { $0.key < $1.key }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // Start from the 1st of the start month
        var currentDate = calendar.date(
            from: calendar.dateComponents([.year, .month], from: startDate)
        )!
        let today = Date()

        var totalShares = 0.0
        var totalInvested = 0.0
        var series: [DCADataPoint] = []

        while currentDate <= today {
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: currentDate)!

            // Find first available price in this month
            let monthPrice = sortedPrices
                .first { $0.key >= currentDate && $0.key < monthEnd }?
                .value

            if let price = monthPrice, price > 0 {
                totalShares += monthlyAmount / price
                totalInvested += monthlyAmount
            }

            // Record portfolio value at end-of-month snapshot using last known price
            if let lastKnownPrice = sortedPrices.last(where: { $0.key <= currentDate })?.value {
                series.append(DCADataPoint(date: currentDate, value: totalShares * lastKnownPrice))
            }

            currentDate = monthEnd
        }

        guard totalInvested > 0 else {
            errorMessage = "No price data found in the selected date range."
            isCalculating = false
            return
        }

        let latestPrice = sortedPrices.last?.value ?? 0
        let currentValue = totalShares * latestPrice
        let totalReturn = currentValue - totalInvested
        let returnPercent = (totalReturn / totalInvested) * 100

        results = DCAResults(
            totalInvested: totalInvested,
            currentValue: currentValue,
            totalReturn: totalReturn,
            returnPercent: returnPercent,
            totalShares: totalShares,
            series: series
        )
        isCalculating = false
    }
}

// MARK: - Models

struct DCADataPoint {
    let date: Date
    let value: Double
}

struct DCAResults {
    let totalInvested: Double
    let currentValue: Double
    let totalReturn: Double
    let returnPercent: Double
    let totalShares: Double
    let series: [DCADataPoint]
}
