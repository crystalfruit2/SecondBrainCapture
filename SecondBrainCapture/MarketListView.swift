import SwiftUI

/// The shopping list. Simplest tab in the app on purpose — one text field to
/// add, one list to tick off, no buckets or due dates to reason about.
struct MarketListView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var config: AppConfig
    @State private var showSettings = false
    @State private var toggleFeedback = 0
    @State private var newItemText = ""
    @FocusState private var addFieldFocused: Bool

    private var board: Dashboard? { store.dashboard }
    private var items: [MarketItem] { board?.market ?? [] }
    private var openItems: [MarketItem] { items.filter { !$0.done } }
    private var doneItems: [MarketItem] { items.filter(\.done) }

    var body: some View {
        NavigationStack {
            Group {
                if board != nil {
                    content
                } else if !config.hasToken {
                    DashboardPlaceholder(icon: "key.horizontal",
                                         title: "No token yet",
                                         message: "Add a GitHub token in Settings to see your market list.")
                } else if store.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DashboardPlaceholder(icon: "arrow.clockwise",
                                         title: "Nothing loaded yet",
                                         message: store.lastError ?? "Pull down to fetch your list.")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Market")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(config)
            }
            .safeAreaInset(edge: .bottom) { addBar }
        }
        .task { await store.refreshIfStale() }
    }

    private var content: some View {
        List {
            if store.marketPendingCount > 0 {
                Section {
                    PendingSyncBadge(count: store.marketPendingCount)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if !openItems.isEmpty {
                Section {
                    ForEach(openItems) { item in
                        MarketRow(item: item) { toggle(item) }
                            .listRowInsets(EdgeInsets())
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { toggle(item) } label: {
                                    Label("Got it", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                    }
                } header: {
                    SectionHeader(title: "To buy", count: openItems.count).textCase(nil)
                }
            }

            if !doneItems.isEmpty {
                Section {
                    ForEach(doneItems) { item in
                        MarketRow(item: item) { toggle(item) }
                            .listRowInsets(EdgeInsets())
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { toggle(item) } label: {
                                    Label("Undo", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.orange)
                            }
                    }
                } header: {
                    SectionHeader(title: "In the cart", count: doneItems.count).textCase(nil)
                }
            }

            if items.isEmpty {
                Section {
                    DashboardPlaceholder(icon: "cart",
                                         title: "List's empty",
                                         message: "Add something below — it lands in the vault the moment it syncs.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: toggleFeedback)
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "cart.badge.plus")
                .foregroundStyle(.secondary)
            TextField("Add an item", text: $newItemText)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit(addItem)
            if !newItemText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add", action: addItem)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private func addItem() {
        let trimmed = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addMarketItem(trimmed)
        newItemText = ""
        toggleFeedback += 1
    }

    private func toggle(_ item: MarketItem) {
        store.setMarketDone(item, done: !item.done)
        toggleFeedback += 1
    }
}

#Preview {
    MarketListView()
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
