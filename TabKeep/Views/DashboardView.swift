import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var onSelectGroup: (UUID) -> Void
    var onCreateGroup: () -> Void

    @State private var summary: StatisticsSummary = .empty
    @State private var range: StatisticsRange = .month
    @State private var isLoaded = false
    @State private var now: Date = Date()

    var body: some View {
        Group {
            if store.activeGroups.isEmpty && isLoaded {
                emptyState
            } else {
                statsScroll
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CategoryExpensesQuery.self) { query in
            CategoryExpensesView(category: query.category, range: query.range)
        }
        .navigationDestination(for: GroupsRoute.self) { route in
            switch route {
            case .group(let id):
                GroupDetailView(groupID: id)
            case .expense(let gid, let eid):
                EditExpenseView(groupID: gid, expenseID: eid)
            }
        }
        .task(id: summaryTaskID) {
            now = Date()
            summary = await StatisticsSummary.build(from: store, range: range, now: now)
            withAnimation(.easeInOut(duration: 0.2)) {
                isLoaded = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { summary = await StatisticsSummary.build(from: store, range: range, now: Date()) }
            }
        }
        .onChange(of: range) { _, _ in
            Haptics.selection()
        }
    }

    // MARK: - Loaded scroll content

    private var statsScroll: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroSection
                categorySection
                groupSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, BottomTabBar.height + 24)
        }
        .refreshable {
            await refresh()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            stickyRangePicker
        }
    }

    private func refresh() async {
        await store.foregroundRefresh(force: true)
        await store.retryPendingRates()
        let snapshot = await StatisticsSummary.build(from: store, range: range, now: Date())
        await MainActor.run {
            now = Date()
            summary = snapshot
        }
    }

    private var stickyRangePicker: some View {
        StatisticsRangePicker(selection: $range)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(AppTheme.pageBackground)
    }

    // MARK: - Sections

    private var heroSection: some View {
        HeroTotalCard(
            total: summary.total,
            rangeTitle: summary.rangeTitle,
            currencyCode: summary.defaultCurrencyCode,
            deltaPercent: summary.deltaPercent,
            hasPendingRates: summary.hasPendingRates,
            previousRangeLabel: previousRangeLabel,
            trend: summary.trend,
            granularity: range.bucketGranularity
        )
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("By category")
            CategoryDonutCard(
                stats: summary.byCategory,
                total: summary.total,
                currencyCode: summary.defaultCurrencyCode,
                range: range
            )
        }
    }

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("By group")
            GroupBarsCard(
                stats: summary.byGroup,
                currencyCode: summary.defaultCurrencyCode,
                onTapGroup: onSelectGroup
            )
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty state (preserved)

    private var emptyState: some View {
        CompactEmptyState(
            icon: "square.grid.2x2",
            title: "No groups yet",
            description: "Create a group to see statistics across all your expenses."
        ) {
            Button {
                onCreateGroup()
            } label: {
                Text("Create your first group")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(AppTheme.accent))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("dashboardCreateGroupButton")
        }
    }

    // MARK: - Helpers

    private var summaryTaskID: String {
        "\(store.defaultCurrencyCode)|\(range.taskKey)|\(store.activeGroups.count)|\(expensesFingerprint)"
    }

    private var expensesFingerprint: String {
        // Cover every field that the stats build reads from. `updatedAt`
        // alone would catch most cases (server-stamped on edit), but for
        // local-only mutations that haven't drained yet it's not bumped —
        // include the actual fields too so the dashboard re-builds on
        // category / payer / participant / share edits.
        store.activeGroups.flatMap { group in
            group.expenses.map { e in
                let participants = e.participantIDs.map(\.uuidString).sorted().joined(separator: ":")
                let shares = (e.shares ?? [])
                    .sorted { $0.memberID.uuidString < $1.memberID.uuidString }
                    .map { "\($0.memberID.uuidString):\($0.amount)" }
                    .joined(separator: ",")
                return "\(e.id)-\(e.date.timeIntervalSince1970)-\(e.amount)-\(e.exchangeRate)-\(e.ratePending)-\(e.category.raw)-\(e.payerID)-\(participants)-\(shares)-\(e.updatedAt.timeIntervalSince1970)"
            }
        }.joined(separator: ",")
    }

    private var previousRangeLabel: String? {
        let calendar = Calendar.current
        guard let prior = range.previousInterval(now: now, calendar: calendar) else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        switch range {
        case .month:
            f.setLocalizedDateFormatFromTemplate("MMMM")
            return f.string(from: prior.start)
        case .year:
            f.setLocalizedDateFormatFromTemplate("y")
            return f.string(from: prior.start)
        case .allTime:
            return nil
        case .custom:
            return "prior period"
        }
    }
}
