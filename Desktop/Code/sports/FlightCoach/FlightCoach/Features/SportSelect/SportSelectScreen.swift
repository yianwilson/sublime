import SwiftUI

struct SportSelectScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSport: SportType?
    @State private var navigateToSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Select Sport")
                    .font(.largeTitle.bold())
                    .padding(.top, 32)

                Text("Choose the sport you're practising today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 16) {
                    ForEach(SportType.allCases) { sport in
                        SportSelectCard(sport: sport, isSelected: selectedSport == sport)
                            .onTapGesture {
                                selectedSport = sport
                            }
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                Button {
                    if selectedSport != nil { navigateToSetup = true }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(selectedSport != nil ? Color.green : Color.gray.opacity(0.3))
                        .foregroundStyle(selectedSport != nil ? .white : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(selectedSport == nil)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $navigateToSetup) {
                if let sport = selectedSport {
                    SessionSetupScreen(sport: sport)
                }
            }
        }
    }
}

struct SportSelectCard: View {
    let sport: SportType
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: sport.iconName)
                .font(.system(size: 32))
                .foregroundStyle(isSelected ? .white : .green)
                .frame(width: 56, height: 56)
                .background(isSelected ? Color.green : Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(sport.displayName)
                    .font(.headline)
                Text(sport == .golf ? "Swing analysis, ball tracking" : "Stroke analysis, contact detection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(isSelected ? Color.green.opacity(0.1) : Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.green : .clear, lineWidth: 2))
    }
}
