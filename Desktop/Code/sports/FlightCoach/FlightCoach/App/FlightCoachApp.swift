import SwiftUI
import SwiftData

@main
struct FlightCoachApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: PracticeSession.self)
        }
    }
}
