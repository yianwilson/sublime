import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var portfoliosVM = PortfoliosViewModel()
    @AppStorage("colorScheme") private var colorSchemePreference = "system"

    private var preferredColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(portfoliosVM)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
