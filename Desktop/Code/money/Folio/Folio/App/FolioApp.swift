import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var portfolioVM = PortfolioViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(portfolioVM)
                .preferredColorScheme(.dark)
        }
    }
}
