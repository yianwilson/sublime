import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: PortfolioViewModel
    @StateObject private var watchlistVM = WatchlistViewModel()

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Dashboard", systemImage: "chart.pie.fill")
            }

            NavigationStack {
                PortfolioListView()
            }
            .tabItem {
                Label("Portfolio", systemImage: "list.bullet.rectangle")
            }

            NavigationStack {
                WatchlistView()
            }
            .environmentObject(watchlistVM)
            .tabItem {
                Label("Watchlist", systemImage: "star")
            }
        }
        .task {
            await vm.refreshPrices()
            await watchlistVM.refreshQuotes()
        }
    }
}
