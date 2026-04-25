import SwiftUI

struct ManagePortfoliosView: View {
    @EnvironmentObject private var portfoliosVM: PortfoliosViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renaming: NamedPortfolio? = nil
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Portfolios") {
                    ForEach(portfoliosVM.portfolios) { portfolio in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(portfolio.name)
                                    .font(.subheadline.weight(.medium))
                                Text("\(portfolio.transactions.count) transactions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if portfolio.id == portfoliosVM.activePortfolioId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            portfoliosVM.activePortfolioId = portfolio.id
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if portfoliosVM.portfolios.count > 1 {
                                Button(role: .destructive) {
                                    portfoliosVM.delete(portfolio)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            Button {
                                renaming = portfolio
                                renameText = portfolio.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }

                Section("New Portfolio") {
                    HStack {
                        TextField("Portfolio name", text: $newName)
                        Button("Create") {
                            portfoliosVM.createPortfolio(name: newName)
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Portfolios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Portfolio", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let p = renaming {
                        portfoliosVM.rename(p, to: renameText)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }
}
