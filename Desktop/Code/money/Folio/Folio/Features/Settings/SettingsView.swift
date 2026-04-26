import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var portfolioVM: PortfolioViewModel

    @AppStorage("colorScheme") private var colorSchemePreference = "system"

    @State private var showClearDataAlert = false

    private let persistence = PersistenceService()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Appearance
                Section("Appearance") {
                    Picker("Color Scheme", selection: $colorSchemePreference) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: - Data
                Section("Data") {
                    Button(role: .destructive) {
                        showClearDataAlert = true
                    } label: {
                        Label("Clear All Data", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(buildNumber)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Clear All Data", isPresented: $showClearDataAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    persistence.clearAllData()
                }
            } message: {
                Text("This will delete all transactions and snapshots. This cannot be undone.")
            }
        }
    }
}
