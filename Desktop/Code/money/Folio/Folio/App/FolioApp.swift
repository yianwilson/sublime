import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var portfoliosVM = PortfoliosViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(portfoliosVM)
                .preferredColorScheme(.dark)
        }
    }
}
