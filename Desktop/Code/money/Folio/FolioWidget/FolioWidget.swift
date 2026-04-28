import WidgetKit
import SwiftUI

// MARK: - Data Loading

/// Mirrors PerformanceSnapshot from the main app (date + totalValue).
struct WidgetSnapshot: Codable {
    let date: Date
    let totalValue: Double
}

struct WidgetData {
    let portfolioValue: Double
    let portfolioName: String
    let lastUpdated: Date

    static let placeholder = WidgetData(
        portfolioValue: 12345.67,
        portfolioName: "My Portfolio",
        lastUpdated: Date()
    )
    static let empty = WidgetData(
        portfolioValue: 0,
        portfolioName: "Folio",
        lastUpdated: Date()
    )
}

func loadWidgetData() -> WidgetData {
    guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        return .empty
    }

    // Load latest performance snapshot — file name matches PersistenceService.snapshotsFileURL
    let snapshotsURL = documentsURL.appendingPathComponent("performance-snapshots.json")
    var portfolioValue = 0.0
    var lastUpdated = Date()

    if let data = try? Data(contentsOf: snapshotsURL),
       let snapshots = try? JSONDecoder().decode([WidgetSnapshot].self, from: data),
       let latest = snapshots.sorted(by: { $0.date > $1.date }).first {
        portfolioValue = latest.totalValue
        lastUpdated = latest.date
    }

    // Load active portfolio name from portfolios.json
    var portfolioName = "My Portfolio"
    let portfoliosURL = documentsURL.appendingPathComponent("portfolios.json")

    if let data = try? Data(contentsOf: portfoliosURL) {
        // NamedPortfolio JSON: [{"id":..., "name":..., "transactions":[...], "createdAt":...}]
        // Decode only the fields we need using a lightweight struct
        struct NameStub: Codable { let name: String }
        if let stubs = try? JSONDecoder().decode([NameStub].self, from: data),
           let first = stubs.first {
            portfolioName = first.name
        }
    }

    return WidgetData(
        portfolioValue: portfolioValue,
        portfolioName: portfolioName,
        lastUpdated: lastUpdated
    )
}

// MARK: - Timeline

struct FolioEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct FolioProvider: TimelineProvider {
    func placeholder(in context: Context) -> FolioEntry {
        FolioEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FolioEntry) -> Void) {
        completion(FolioEntry(date: Date(), data: loadWidgetData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FolioEntry>) -> Void) {
        let entry = FolioEntry(date: Date(), data: loadWidgetData())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - Views

struct FolioWidgetEntryView: View {
    var entry: FolioEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.data.portfolioName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(
                entry.data.portfolioValue,
                format: .currency(code: "AUD").presentation(.narrow)
            )
            .font(family == .systemSmall ? .title2.bold() : .title.bold())
            .minimumScaleFactor(0.7)
            .lineLimit(1)

            Text("Updated \(entry.data.lastUpdated.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .containerBackground(Color(.systemBackground), for: .widget)
    }
}

// MARK: - Widget

@main
struct FolioWidget: Widget {
    let kind = "FolioWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FolioProvider()) { entry in
            FolioWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Folio Portfolio")
        .description("See your portfolio value at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
