import SwiftUI

struct ContentView: View {
    @ObservedObject var portfolioVM: PortfolioViewModel
    @EnvironmentObject private var portfoliosVM: PortfoliosViewModel
    @StateObject private var watchlistVM = WatchlistViewModel()
    @State private var showPortfolios = false

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                showPortfolios = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(portfoliosVM.activePortfolio?.name ?? "Portfolio")
                                        .font(.subheadline.weight(.medium))
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                }
                            }
                        }
                    }
            }
            .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }

            NavigationStack { PortfolioListView() }
                .tabItem { Label("Portfolio", systemImage: "list.bullet.rectangle") }

            NavigationStack { WatchlistView() }
                .environmentObject(watchlistVM)
                .tabItem { Label("Watchlist", systemImage: "star") }

            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }
        }
        .environmentObject(portfolioVM)
        .sheet(isPresented: $showPortfolios) {
            ManagePortfoliosView()
                .environmentObject(portfoliosVM)
        }
        .task {
            await AlertsService.shared.requestPermission()
            await portfolioVM.refreshPrices()
            await watchlistVM.refreshQuotes()
        }
    }
}
