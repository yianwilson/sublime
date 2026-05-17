import SwiftUI
import SwiftData

struct HomeScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeSession.createdAt, order: .reverse) private var recentSessions: [PracticeSession]

    @State private var showSportSelect = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    headerView
                    Spacer()
                    ctaSection
                    Spacer()
                    if !recentSessions.isEmpty {
                        recentSection
                    }
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .sheet(isPresented: $showSportSelect) {
                SportSelectScreen()
            }
            .navigationDestination(isPresented: $showHistory) {
                SessionHistoryScreen()
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FlightCoach")
                        .font(.largeTitle.bold())
                    Text("Local-only · No cloud · All private")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
    }

    private var ctaSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.golf")
                .font(.system(size: 72))
                .foregroundStyle(.green.gradient)

            Text("Analyse Your Game")
                .font(.title2.weight(.semibold))

            Text("Record or import a practice video.\nAll analysis happens on your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showSportSelect = true
            } label: {
                Label("Start New Session", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Sessions")
                    .font(.headline)
                Spacer()
                Button("See All") { showHistory = true }
                    .font(.subheadline)
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentSessions.prefix(5)) { session in
                        NavigationLink(destination: AnalysisResultScreen(session: session)) {
                            SessionThumbnailCard(session: session)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 32)
    }
}
