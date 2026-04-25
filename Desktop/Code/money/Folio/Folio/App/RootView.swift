import SwiftUI

/// Rebuilds PortfolioViewModel whenever the active portfolio changes.
struct RootView: View {
    @EnvironmentObject private var portfoliosVM: PortfoliosViewModel

    var body: some View {
        if let portfolio = portfoliosVM.activePortfolio {
            ContentView(portfolioVM: makeVM(for: portfolio))
                .id(portfolio.id)   // forces rebuild when active portfolio switches
                .environmentObject(portfoliosVM)
        }
    }

    private func makeVM(for portfolio: NamedPortfolio) -> PortfolioViewModel {
        let vm = PortfolioViewModel(portfolio: portfolio)
        vm.portfoliosVM = portfoliosVM
        return vm
    }
}
