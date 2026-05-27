import SwiftUI

struct GroupDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID

    enum Tab: Hashable {
        case expenses, balances

        fileprivate var index: Int {
            switch self {
            case .expenses: return 0
            case .balances: return 1
            }
        }
    }
    @State private var tab: Tab = .expenses
    @State private var showingEditGroup = false
    @State private var showingAddExpense = false
    @State private var showingArchiveConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingLeaveConfirm = false
    @State private var showingNotSettledAlert = false
    @State private var pendingAction: PendingAction = .none

    private enum PendingAction { case none, archive, delete }

    private struct SettlementPaymentContext: Identifiable {
        let id = UUID()
        let from: Member
        let to: Member
        let suggestedAmount: Decimal
    }

    private struct EditingPaymentID: Identifiable {
        let id: UUID
    }

    @State private var categoryFilter: ExpenseCategory? = nil
    @State private var payerFilter: UUID? = nil
    @State private var dateRange: DateRangePreset = .allTime
    @State private var showingFilters = false
    @State private var everyoneElseExpanded = false
    @State private var recordedPaymentsExpanded = false
    @State private var pendingSettlementPayment: SettlementPaymentContext?
    @State private var editingPaymentID: EditingPaymentID?
    @State private var tabSlideEdge: Edge = .trailing
    @State private var searchText: String = ""

    @State private var inviteShareURL: URL?
    @State private var inviteIsMinting = false
    @State private var inviteErrorText: String?

    /// Drives the collapsing pill + search row. Hidden while the user
    /// scrolls downward through the list and revealed again on upward
    /// scroll (Apple-style auto-hiding sub-header).
    @State private var tabBarVisible: Bool = true
    @State private var lastScrollY: CGFloat = 0

    private var group: ExpenseGroup? { store.group(id: groupID) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 14) {
                if tabBarVisible {
                    PillSegmented(
                        items: [
                            .init(
                                label: "Expenses",
                                tag: .expenses,
                                badge: expensesBadge
                            ),
                            .init(
                                label: "Balances",
                                tag: .balances,
                                badge: balancesBadge,
                                badgeAlert: pendingSettlementCount > 0
                            )
                        ],
                        selection: tabBinding,
                        tint: AppTheme.accent,
                        compact: true
                    )
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))

                    if tab == .expenses {
                        searchRow
                            .padding(.horizontal)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                if isArchived {
                    archivedBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }

                if let g = group {
                    Group {
                        switch tab {
                        case .expenses:
                            GroupHeaderCard(
                                group: g,
                                accent: accent,
                                settlementCount: store.settlements(forGroup: g.id).count,
                                total: groupTotal(in: g)
                            )
                        case .balances:
                            balancesTopCard(group: g)
                        }
                    }
                    .padding(.horizontal, 16)
                    .id(tab)
                    .transition(slideTransition)
                }

                Group {
                    switch tab {
                    case .expenses: expensesTab
                    case .balances: balancesTab
                    }
                }
                .id(tab)
                .transition(slideTransition)
                .clipped()
            }
            .ignoresSafeArea(.container, edges: .bottom)

            if tab == .expenses && !isArchived {
                floatingAddButton
            }
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(group?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.refresh(groupID: groupID)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                groupMenu
            }
        }
        .sheet(isPresented: $showingEditGroup) {
            CreateGroupSheet(mode: .edit(groupID: groupID))
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView(groupID: groupID)
        }
        .sheet(isPresented: $showingFilters) {
            filtersSheet
        }
        .sheet(item: $pendingSettlementPayment) { ctx in
            RecordPaymentSheet(
                groupID: groupID,
                from: ctx.from,
                to: ctx.to,
                suggestedAmount: ctx.suggestedAmount
            )
        }
        .sheet(item: $editingPaymentID) { wrapper in
            EditPaymentSheet(groupID: groupID, paymentID: wrapper.id)
        }
        .sheet(item: Binding(
            get: { inviteShareURL.map(InviteShareWrapper.init) },
            set: { _ in inviteShareURL = nil }
        )) { wrapper in
            ShareLinkSheet(url: wrapper.url)
        }
        .overlay {
            if inviteIsMinting {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView().scaleEffect(1.5)
                }
            }
        }
        .overlay(alignment: .top) {
            if let inviteErrorText {
                Text(inviteErrorText)
                    .font(.footnote).bold()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.92), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            isArchived ? "Unarchive this group?" : "Archive this group?",
            isPresented: $showingArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button(isArchived ? "Unarchive" : "Archive") { toggleArchive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isArchived
                 ? "The group will be visible in the main list again."
                 : "The group will be hidden from the main list but kept for reference.")
        }
        .confirmationDialog(
            "Delete this group?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All expenses, balances and receipt photos will be removed. This can't be undone.")
        }
        .confirmationDialog(
            "Leave this group?",
            isPresented: $showingLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave group", role: .destructive) { leaveGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll lose access to this group on this device. Other members can still see your past expenses.")
        }
        .alert("Settle up first", isPresented: $showingNotSettledAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notSettledMessage)
        }
        .onChange(of: store.group(id: groupID) == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private var isArchived: Bool { group?.archivedAt != nil }

    private var archivedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Archived — read-only")
                    .font(.subheadline.weight(.semibold))
                Text("Unarchive from the menu to make changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var isSettled: Bool {
        store.settlements(forGroup: groupID).isEmpty
    }

    private var groupMenu: some View {
        Menu {
            if !isArchived {
                Button {
                    showingEditGroup = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }

            if !isArchived && store.isHost(of: groupID) {
                Button {
                    inviteTapped()
                } label: {
                    Label("Invite people", systemImage: "person.badge.plus")
                }
            }

            Section {
                Button {
                    requestArchive()
                } label: {
                    Label(isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                }

                if store.isShared(groupID) && !store.isHost(of: groupID) {
                    Button {
                        showingLeaveConfirm = true
                    } label: {
                        Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }

            if store.isHost(of: groupID) || !store.isShared(groupID) {
                Section {
                    Button(role: .destructive) {
                        requestDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .accessibilityIdentifier("groupOptionsButton")
        .accessibilityLabel("Group options")
    }

    private func requestArchive() {
        // Unarchive is always allowed.
        if !isArchived && !isSettled {
            pendingAction = .archive
            showingNotSettledAlert = true
            return
        }
        showingArchiveConfirm = true
    }

    private func requestDelete() {
        if !isSettled {
            pendingAction = .delete
            showingNotSettledAlert = true
            return
        }
        showingDeleteConfirm = true
    }

    private func inviteTapped() {
        inviteIsMinting = true
        inviteErrorText = nil
        Task {
            defer { inviteIsMinting = false }
            do {
                inviteShareURL = try await store.createInvite(for: groupID)
            } catch {
                let text = "Couldn't create invite link. Try again."
                inviteErrorText = text
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if inviteErrorText == text {
                    inviteErrorText = nil
                }
            }
        }
    }

    private var notSettledMessage: String {
        switch pendingAction {
        case .archive:
            return "There are outstanding settlements in this group. Record the remaining payments on the Balances tab, then try archiving again."
        case .delete:
            return "There are outstanding settlements in this group. Record the remaining payments on the Balances tab, then try deleting again."
        case .none:
            return "There are outstanding settlements in this group."
        }
    }

    private func toggleArchive() {
        let archived = isArchived
        let id = groupID
        if archived {
            Task { _ = try? await store.unarchiveGroup(id: id) }
        } else {
            Task { _ = try? await store.archiveGroup(id: id) }
            dismiss()
        }
    }

    private func deleteGroup() {
        let id = groupID
        Task {
            do {
                try await store.deleteGroup(id: id)
                // onChange(of: store.group(id:) == nil) pops automatically once
                // the group is removed from local state.
            } catch AppStoreError.forbidden {
                let text = "Only the host can delete this group. Use Leave group instead."
                inviteErrorText = text
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if inviteErrorText == text { inviteErrorText = nil }
            } catch {
                let text = "Couldn't delete group. Try again."
                inviteErrorText = text
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if inviteErrorText == text { inviteErrorText = nil }
            }
        }
    }

    private func leaveGroup() {
        let id = groupID
        Task {
            do {
                try await store.leaveGroup(id)
                // onChange(of: store.group(id:) == nil) pops automatically once
                // the group is removed from local state.
            } catch {
                let text = "Couldn't leave group. Try again."
                inviteErrorText = text
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if inviteErrorText == text {
                    inviteErrorText = nil
                }
            }
        }
    }

    private var accent: Color { AppTheme.accent }

    private func openRecordSheet(group: ExpenseGroup, settlement: Settlement) {
        guard let from = group.members.first(where: { $0.id == settlement.fromMemberID }),
              let to = group.members.first(where: { $0.id == settlement.toMemberID })
        else { return }
        pendingSettlementPayment = SettlementPaymentContext(
            from: from,
            to: to,
            suggestedAmount: settlement.amount
        )
    }

    private var tabBinding: Binding<Tab> {
        Binding(
            get: { tab },
            set: { newValue in
                // Update the slide edge synchronously *before* the tab so the
                // transition reads the correct direction on the same render.
                tabSlideEdge = newValue.index > tab.index ? .leading : .trailing
                tab = newValue
            }
        )
    }

    private var slideTransition: AnyTransition {
        // Single-edge .move so each view's last-rendered direction governs
        // both its insertion and removal. With the custom tabBinding setting
        // tabSlideEdge before tab changes, the leaving view exits toward the
        // edge it was rendered with, and the entering view comes in from
        // the edge captured at the new render.
        .move(edge: tabSlideEdge).combined(with: .opacity)
    }

    // MARK: - Scroll-driven tab picker visibility

    /// Updates `tabBarVisible` based on a fresh scroll offset (positive y =
    /// scrolled down, matching UIKit's contentOffset). Uses two absolute
    /// thresholds with a 60pt hysteresis band so hiding the picker — which
    /// reflows the ScrollView's frame and produces another scroll event —
    /// can't bounce the visibility back. No dependency on direction/delta.
    private func handleScrollOffset(_ newY: CGFloat) {
        let hideAbove: CGFloat = 80
        let showBelow: CGFloat = 20
        if newY > hideAbove, tabBarVisible {
            withAnimation(.easeOut(duration: 0.2)) { tabBarVisible = false }
        } else if newY < showBelow, !tabBarVisible {
            withAnimation(.easeOut(duration: 0.2)) { tabBarVisible = true }
        }
        lastScrollY = newY
    }

    private var expensesBadge: String? {
        let count = group?.expenses.count ?? 0
        return count > 0 ? "\(count)" : nil
    }

    private var pendingSettlementCount: Int {
        guard let g = group else { return 0 }
        return store.settlements(forGroup: g.id).count
    }

    private var balancesBadge: String? {
        pendingSettlementCount > 0 ? "\(pendingSettlementCount)" : nil
    }

    private func groupTotal(in group: ExpenseGroup) -> Decimal {
        group.expenses.reduce(Decimal(0)) { acc, e in acc + (e.amount * e.exchangeRate) }
    }

    private func resolveMe(in group: ExpenseGroup) -> Member? {
        guard store.user.hasName else { return nil }
        let key = store.user.matchKey
        return group.members.first {
            $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key
        }
    }

    private func myPaid(in group: ExpenseGroup, me: Member) -> Decimal {
        group.expenses
            .filter { $0.payerID == me.id }
            .reduce(Decimal(0)) { acc, e in acc + (e.amount * e.exchangeRate) }
    }

    private func myOwes(_ settlements: [Settlement], me: Member) -> Decimal {
        settlements
            .filter { $0.fromMemberID == me.id }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    private func myReceives(_ settlements: [Settlement], me: Member) -> Decimal {
        settlements
            .filter { $0.toMemberID == me.id }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }

    // MARK: - Floating add button

    private var floatingAddButton: some View {
        Button {
            showingAddExpense = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(AppTheme.accent.gradient)
                )
                .shadow(color: accent.opacity(0.35), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityIdentifier("groupAddExpenseButton")
        .accessibilityLabel("Add expense")
    }

    // MARK: - Expenses

    @ViewBuilder
    private var expensesTab: some View {
        if let g = group {
            let filtered = filteredExpenses(g.expenses)
            if filtered.isEmpty {
                ScrollView {
                    expensesEmptyState
                }
                .refreshable {
                    if let g = group {
                        await store.refresh(groupID: g.id, force: true)
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                let buckets = groupByDay(filtered)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(buckets) { bucket in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Self.dayLabel(for: bucket.date))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                                    .padding(.horizontal, 4)
                                VStack(spacing: 12) {
                                    ForEach(bucket.expenses) { expense in
                                        NavigationLink(value: GroupsRoute.expense(groupID: g.id, expenseID: expense.id)) {
                                            ExpenseRow(group: g, expense: expense)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .modifier(ScrollOffsetTracker(handler: handleScrollOffset))
                .refreshable {
                    if let g = group {
                        await store.refresh(groupID: g.id, force: true)
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }

    /// Search field + filter button as a single inline row, rendered under
    /// the Expenses/Balances pill on the Expenses tab. Replaces the prior
    /// toolbar-based placement.
    private var searchRow: some View {
        HStack(spacing: 10) {
            ExpensesSearchField(text: $searchText)
            filterButton
        }
    }

    private var filterButton: some View {
        Button {
            showingFilters = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle" + (hasAnyFilter ? ".fill" : ""))
                .font(.body)
                .foregroundStyle(hasAnyFilter ? AppTheme.accent : .primary)
        }
        .accessibilityLabel(hasAnyFilter ? "Filters, \(activeFilterCount) active" : "Filters")
        .accessibilityIdentifier("filtersButton")
    }

    private var activeFilterCount: Int {
        var n = 0
        if categoryFilter != nil { n += 1 }
        if payerFilter != nil { n += 1 }
        if case .allTime = dateRange { /* no-op */ } else { n += 1 }
        return n
    }

    @ViewBuilder
    private var filtersSheet: some View {
        let counts = CategoryTotals.counts(for: group?.expenses ?? [])
        // Active members only — archived members shouldn't appear in the
        // payer-filter picker. Their past expenses still resolve via the
        // expense list rendering paths (which don't filter members).
        let members = (group?.members ?? []).pickable(currentUserServerID: store.user.serverID)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filterCard(title: "Category") {
                        categoryChipsView(counts: counts)
                    }
                    filterCard(title: "Paid by") {
                        payerPickerView(members: members)
                    }
                    filterCard(title: "Date range") {
                        dateRangePickerView
                    }
                }
                .padding(16)
            }
            .background(AppTheme.sheetBackground.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear all") {
                        categoryFilter = nil
                        payerFilter = nil
                        dateRange = .allTime
                    }
                    .disabled(!hasAnyFilter)
                    .accessibilityIdentifier("clearFiltersButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingFilters = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(32)
    }

    private func categoryChipsView(counts: [ExpenseCategory: Int]) -> some View {
        // Built-ins always show; custom categories show only when they
        // have at least one expense in this group.
        let categories: [ExpenseCategory] = ExpenseCategory.builtIn +
            counts.keys
                .filter { !$0.isBuiltIn && (counts[$0] ?? 0) > 0 }
                .sorted { $0.raw < $1.raw }
        return FlowLayout(spacing: 8, lineSpacing: 8) {
            categoryChip(category: nil, count: nil)
            ForEach(categories, id: \.self) { c in
                categoryChip(category: c, count: counts[c])
            }
        }
    }

    @ViewBuilder
    private func categoryChip(category: ExpenseCategory?, count: Int?) -> some View {
        let isSelected = category == nil ? categoryFilter == nil : categoryFilter == category
        Button {
            if let category {
                categoryFilter = (categoryFilter == category) ? nil : category
            } else {
                categoryFilter = nil
            }
        } label: {
            HStack(spacing: 6) {
                if let category {
                    Image(category.lucideIconName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption.weight(.bold))
                }
                Text(category?.displayName ?? "All")
                    .font(.callout.weight(.medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? AppTheme.accent : AppTheme.pageBackground)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : AppTheme.borderHairline, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(category.map { "categoryFilterChip_\($0.raw)" } ?? "categoryFilterChip_all")
    }

    private func payerPickerView(members: [Member]) -> some View {
        VStack(spacing: 6) {
            payerRow(
                label: "Anyone",
                isSelected: payerFilter == nil,
                avatar: { iconAvatar(systemName: "person.2.fill") }
            ) {
                payerFilter = nil
            }
            ForEach(members) { m in
                payerRow(
                    label: m.name,
                    isSelected: payerFilter == m.id,
                    avatar: { AnyView(AvatarView(emoji: m.emoji, size: 30)) }
                ) {
                    payerFilter = (payerFilter == m.id) ? nil : m.id
                }
            }
        }
    }

    private func iconAvatar(systemName: String) -> AnyView {
        AnyView(
            ZStack {
                Circle().fill(AppTheme.pageBackground)
                Image(systemName: systemName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)
            .overlay(
                Circle().strokeBorder(AppTheme.borderHairline, lineWidth: 1)
            )
        )
    }

    private func payerRow(
        label: String,
        isSelected: Bool,
        avatar: () -> AnyView,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                avatar()
                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : AppTheme.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.30) : AppTheme.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Date range picker (inline)

    private var dateRangePickerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                datePresetChip(.allTime, label: "All time")
                datePresetChip(.thisWeek, label: "This week")
                datePresetChip(.thisMonth, label: "This month")
                datePresetChip(.last30Days, label: "Last 30 days")
                customDateChip
            }
            if case .custom(let start, let end) = dateRange {
                customRangeEditor(start: start, end: end)
            }
        }
    }

    private func datePresetChip(_ preset: DateRangePreset, label: String) -> some View {
        let isSelected = dateRange == preset
        return Button {
            dateRange = preset
        } label: {
            Text(label)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    Capsule().fill(isSelected ? AppTheme.accent : AppTheme.pageBackground)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : AppTheme.borderHairline, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var customDateChip: some View {
        let isSelected: Bool = {
            if case .custom = dateRange { return true }
            return false
        }()
        return Button {
            if case .custom = dateRange { return }
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
            dateRange = .custom(start: start, end: end)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.bold))
                Text(customChipLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? AppTheme.accent : AppTheme.pageBackground)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : Color(.separator), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var customChipLabel: String {
        guard case .custom(let s, let e) = dateRange else { return "Custom" }
        return "\(Self.shortDate.string(from: s)) – \(Self.shortDate.string(from: e))"
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func customRangeEditor(start: Date, end: Date) -> some View {
        VStack(spacing: 6) {
            DatePicker(
                "From",
                selection: Binding(
                    get: { start },
                    set: { newStart in
                        let safeEnd = max(end, newStart)
                        dateRange = .custom(start: newStart, end: safeEnd)
                    }
                ),
                displayedComponents: .date
            )
            Divider().opacity(0.4)
            DatePicker(
                "To",
                selection: Binding(
                    get: { end },
                    set: { newEnd in
                        dateRange = .custom(start: min(start, newEnd), end: newEnd)
                    }
                ),
                in: start...,
                displayedComponents: .date
            )
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.pageBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
        .tint(AppTheme.accent)
    }

    @ViewBuilder
    private func filterCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            HStack {
                content()
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
    }

    private var hasAnyFilter: Bool {
        if categoryFilter != nil { return true }
        if payerFilter != nil { return true }
        if case .allTime = dateRange { return false }
        return true
    }

    @ViewBuilder
    private var expensesEmptyState: some View {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("No matches for \"\(trimmedQuery)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityIdentifier("expensesSearchEmptyState")
        } else if hasAnyFilter {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text("No expenses match. Clear a filter to see more.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else {
            blankExpensesCard
        }
    }

    /// True when the group has only the host (no other active members).
    /// Drives the "Invite people" CTA in the empty-expenses card.
    private var isSoloGroup: Bool {
        let activeCount = (group?.members ?? []).filter { $0.archivedAt == nil }.count
        return activeCount <= 1
    }

    private var blankExpensesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title3)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No expenses yet")
                        .font(.subheadline.weight(.semibold))
                    Text(isSoloGroup
                         ? "Add your first expense, or invite someone to split with."
                         : "Tap + to add the first one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if isSoloGroup {
                Button {
                    inviteTapped()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus")
                            .font(.footnote.weight(.semibold))
                        Text("Invite people")
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.accent)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("emptyExpensesInvitePeopleButton")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func filteredExpenses(_ expenses: [Expense]) -> [Expense] {
        var result = expenses.sorted(by: { $0.date > $1.date })
        if let filter = categoryFilter {
            result = result.filter { $0.category == filter }
        }
        if let pid = payerFilter {
            result = result.filter { $0.payerID == pid }
        }
        if let interval = dateRange.interval() {
            result = result.filter { interval.contains($0.date) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            let members = group?.members ?? []
            result = result.filter { expense in
                if expense.description.lowercased().contains(query) { return true }
                if let payer = members.first(where: { $0.id == expense.payerID }),
                   payer.name.lowercased().contains(query) {
                    return true
                }
                return false
            }
        }
        return result
    }

    private func groupByDay(_ expenses: [Expense]) -> [ExpenseDayBucket] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: expenses) { cal.startOfDay(for: $0.date) }
        return grouped
            .map { day, items in
                ExpenseDayBucket(date: day, expenses: items.sorted(by: { $0.date > $1.date }))
            }
            .sorted(by: { $0.date > $1.date })
    }

    private static let dayHeaderFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.doesRelativeDateFormatting = true
        return df
    }()

    private static func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return dayHeaderFormatter.string(from: date)
    }

    // MARK: - Balances

    @ViewBuilder
    private var balancesTab: some View {
        if let g = group {
            let balances = store.balances(forGroup: g.id)
            let settlements = store.settlements(forGroup: g.id)
            let pendingCount = store.pendingRatesCount(forGroup: g.id)
            let me = resolveMe(in: g)
            let mySettlements = me.map { meMember in
                settlements.filter { $0.fromMemberID == meMember.id || $0.toMemberID == meMember.id }
            } ?? []
            let otherSettlements = me.map { meMember in
                settlements.filter { $0.fromMemberID != meMember.id && $0.toMemberID != meMember.id }
            } ?? settlements
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if pendingCount > 0 {
                        pendingRatesBanner(count: pendingCount)
                            .padding(.horizontal)
                    }

                    if me != nil {
                        mySettlementsSection(group: g, settlements: mySettlements)
                    }

                    everyoneElseSection(
                        group: g,
                        otherSettlements: otherSettlements,
                        balances: balances,
                        showsMyDivider: me != nil
                    )

                    if let payments = g.payments, !payments.isEmpty {
                        recordedPaymentsSection(group: g, payments: payments)
                    }
                }
                .padding(.bottom, 24)
            }
            .modifier(ScrollOffsetTracker(handler: handleScrollOffset))
            .refreshable {
                if let g = group {
                    await store.refresh(groupID: g.id, force: true)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func recordedPaymentsSection(group: ExpenseGroup, payments: [Payment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { recordedPaymentsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Recorded payments")
                        .font(.headline)
                    Text("\(payments.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(recordedPaymentsExpanded ? 0 : -90))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if recordedPaymentsExpanded {
                VStack(spacing: 8) {
                    ForEach(payments.sorted(by: { $0.date > $1.date })) { payment in
                        if isArchived {
                            PaymentRow(group: group, payment: payment)
                                .padding(.horizontal, 0)
                                .accessibilityIdentifier("paymentRow_\(payment.id.uuidString)")
                        } else {
                            Button {
                                editingPaymentID = EditingPaymentID(id: payment.id)
                            } label: {
                                PaymentRow(group: group, payment: payment)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("paymentRow_\(payment.id.uuidString)")
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func mySettlementsSection(group: ExpenseGroup, settlements: [Settlement]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My settlements")
                .font(.headline)
                .padding(.horizontal)

            if settlements.isEmpty {
                emptySettlementsHint(text: "You're all settled up here.")
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(settlements.enumerated()), id: \.offset) { _, s in
                        Button {
                            openRecordSheet(group: group, settlement: s)
                        } label: {
                            settlementRow(group: group, settlement: s)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settlementRow_\(s.fromMemberID.uuidString)_\(s.toMemberID.uuidString)")
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func everyoneElseSection(
        group: ExpenseGroup,
        otherSettlements: [Settlement],
        balances: [MemberBalance],
        showsMyDivider: Bool
    ) -> some View {
        let visibleBalances = balances.filter { b in
            group.members.first(where: { $0.id == b.memberID })?.archivedAt == nil
        }
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { everyoneElseExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(showsMyDivider ? "Everyone else" : "Group balances")
                        .font(.headline)
                    Text("\(visibleBalances.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(everyoneElseExpanded ? 0 : -90))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if everyoneElseExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    if !otherSettlements.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Settlements")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)
                                .padding(.horizontal)
                            VStack(spacing: 8) {
                                ForEach(Array(otherSettlements.enumerated()), id: \.offset) { _, s in
                                    Button {
                                        openRecordSheet(group: group, settlement: s)
                                    } label: {
                                        settlementRow(group: group, settlement: s)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("settlementRow_\(s.fromMemberID.uuidString)_\(s.toMemberID.uuidString)")
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Member balances")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.horizontal)
                        VStack(spacing: 8) {
                            ForEach(visibleBalances, id: \.memberID) { b in
                                if let m = group.members.first(where: { $0.id == b.memberID }) {
                                    balanceRow(member: m, amount: b.netAmount, currency: group.currencyCode)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
    }

    private func emptySettlementsHint(text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Self.settledGreen.opacity(0.14))
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Self.settledGreen)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("All settled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .padding(.horizontal)
    }

    // Calibrated functional colors (matches BalanceHeroCard / variant B work)
    fileprivate static let settledGreen  = Color(red: 22.0 / 255.0, green: 163.0 / 255.0, blue: 74.0 / 255.0) // #16A34A
    fileprivate static let oweRed        = Color(red: 220.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0) // #DC2626

    @ViewBuilder
    private func balancesTopCard(group: ExpenseGroup) -> some View {
        let settlements = store.settlements(forGroup: group.id)
        if let me = resolveMe(in: group) {
            PersonalBalanceCard(
                me: me,
                accent: accent,
                currencyCode: group.currencyCode,
                paid: myPaid(in: group, me: me),
                owes: myOwes(settlements, me: me),
                receives: myReceives(settlements, me: me)
            )
        } else {
            GroupHeaderCard(
                group: group,
                accent: accent,
                settlementCount: settlements.count,
                total: groupTotal(in: group)
            )
        }
    }

    private func pendingRatesBanner(count: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Rates unavailable")
                    .font(.callout.weight(.semibold))
                Text("\(count) expense\(count == 1 ? "" : "s") haven't been converted yet. Balances will update once rates can be fetched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await store.retryPendingRates() }
                } label: {
                    Text("Retry")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(store.isRetryingPendingRates)
                .accessibilityIdentifier("retryRatesButton")
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityIdentifier("pendingRatesBanner")
    }

    private func balanceRow(member: Member, amount: Decimal, currency: String) -> some View {
        let label: String
        let color: Color
        if amount > 0 {
            label = "Is owed"
            color = Self.settledGreen
        } else if amount < 0 {
            label = "Owes"
            color = Self.oweRed
        } else {
            label = "Settled"
            color = .secondary
        }
        return HStack(spacing: 12) {
            AvatarView(emoji: member.emoji, size: 34)
            Text(member.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyLabel(amount: amount, currencyCode: currency, font: .subheadline, weight: .bold)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadowColor, radius: 6, x: 0, y: 2)
    }

    private func settlementRow(group: ExpenseGroup, settlement: Settlement) -> some View {
        let from = group.members.first { $0.id == settlement.fromMemberID }
        let to = group.members.first { $0.id == settlement.toMemberID }
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                if let from { AvatarView(emoji: from.emoji, size: 32) }
                Text(from?.name ?? "?")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                if let to { AvatarView(emoji: to.emoji, size: 32) }
                Text(to?.name ?? "?")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyLabel(amount: settlement.amount, currencyCode: group.currencyCode, font: .subheadline, weight: .bold)
                    .foregroundStyle(Self.oweRed)
                Text("Tap to record")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadowColor, radius: 6, x: 0, y: 2)
    }

}

/// Reports the current scroll offset (positive y = scrolled down) to the
/// caller. Uses `onScrollGeometryChange` on iOS 18+ which gives the actual
/// content offset; on iOS 17 it's a no-op (the picker simply stays visible).
private struct ScrollOffsetTracker: ViewModifier {
    let handler: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newY in
                handler(newY)
            }
        } else {
            content
        }
    }
}

private struct ExpensesSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Search expenses", text: $text)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.subheadline)
                .accessibilityIdentifier("expensesSearchField")
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("expensesSearchClear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

private struct ExpenseDayBucket: Identifiable {
    var id: Date { date }
    let date: Date
    let expenses: [Expense]
}

private struct ExpenseRow: View {
    let group: ExpenseGroup
    let expense: Expense
    @Environment(AppStore.self) private var store

    private var hasDraft: Bool {
        store.drafts[.expense(expense.id, in: group.id)] != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if let payer = payer {
                AvatarView(emoji: payer.emoji, size: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(expense.category.lucideIconName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(AppTheme.accent)
                    Text(expense.description.isEmpty ? "Expense" : expense.description)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if hasDraft {
                        Image(systemName: "doc.badge.ellipsis")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if !expense.receipts.isEmpty {
                        Image("paperclip")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(payerCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if showNativeAmount && expense.ratePending {
                    // Rate not yet known — show only the native amount as the
                    // primary number. Avoid fabricating a converted value that
                    // would be wrong (exchangeRate is a placeholder 1 here).
                    // Once retryPendingRates lands, the row recomputes.
                    MoneyLabel(amount: expense.amount, currencyCode: expense.currencyCode, font: .subheadline, weight: .bold)
                    Text("rate pending")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 180.0 / 255.0, green: 83.0 / 255.0, blue: 9.0 / 255.0)) // #B45309 calibrated warning
                } else {
                    MoneyLabel(amount: convertedAmount, currencyCode: group.currencyCode, font: .subheadline, weight: .bold)
                    if showNativeAmount {
                        MoneyLabel(amount: expense.amount, currencyCode: expense.currencyCode, font: .caption2, weight: .regular)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadowColor, radius: 6, x: 0, y: 2)
    }

    private var payer: Member? {
        group.members.first(where: { $0.id == expense.payerID })
    }

    private var payerCaption: String {
        // Multi-payer summary: "Alice + 2 others paid". Primary payer is
        // whatever payerID resolves to (server stores the highest-amount
        // payer there by convention; iOS does the same on save).
        if let payments = expense.payments, payments.count >= 2 {
            let others = payments.count - 1
            return "\(primaryPayerLabel) + \(others) other\(others == 1 ? "" : "s") paid"
        }
        return "\(primaryPayerLabel) paid"
    }

    /// Payer name suffixed with "(deleted)" when the membership is a
    /// ghost (owning user deleted their account). Surfaces the missing-
    /// counterparty status in historical rows so the host doesn't expect
    /// the person to settle going forward.
    private var primaryPayerLabel: String {
        guard let payer else { return "Unknown" }
        return payer.isGhost ? "\(payer.name) (deleted)" : payer.name
    }

    private var convertedAmount: Decimal {
        expense.amount * expense.exchangeRate
    }

    private var showNativeAmount: Bool {
        expense.currencyCode != group.currencyCode
    }
}

// MARK: - Group header card

private struct GroupHeaderCard: View {
    let group: ExpenseGroup
    let accent: Color
    let settlementCount: Int
    let total: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                EmojiText(emoji: group.emoji ?? "👥", size: 32)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.32), accent.opacity(0.14)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        let activeCount = group.members.filter { $0.archivedAt == nil }.count
                        Text("\(activeCount) member\(activeCount == 1 ? "" : "s")")
                        Text("·")
                        Text(group.currencyCode).monospaced()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                GroupHeaderStatus(settlementCount: settlementCount)
            }

            Divider().opacity(0.4)

            totalStat(label: "All expenses", value: total)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.emphasisCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadowColor, radius: 8, x: 0, y: 3)
        .environment(\.colorScheme, .dark)
    }

    private func totalStat(label: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value.formatted(.currency(code: group.currencyCode)))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Personal balance card (Balances tab)

private struct PersonalBalanceCard: View {
    let me: Member
    let accent: Color
    let currencyCode: String
    let paid: Decimal
    let owes: Decimal
    let receives: Decimal

    private var net: Decimal { receives - owes }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AvatarView(emoji: me.emoji, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(me.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        YouBadge()
                    }
                    Text(currencyCode).monospaced()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                netBadge
            }

            Divider().opacity(0.4)

            HStack(alignment: .top, spacing: 12) {
                stat(label: "I paid", value: paid, color: .primary)
                Divider().frame(height: 36).opacity(0.4)
                stat(label: "I owe", value: owes, color: owes > 0 ? .red : .secondary)
                Divider().frame(height: 36).opacity(0.4)
                stat(label: "I'm owed", value: receives, color: receives > 0 ? .green : .secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.emphasisCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadowColor, radius: 8, x: 0, y: 3)
        .environment(\.colorScheme, .dark)
    }

    private var netBadge: some View {
        let isPositive = net > 0
        let isNeutral = net == 0
        return HStack(spacing: 4) {
            Image(systemName: isNeutral
                  ? "checkmark.seal.fill"
                  : (isPositive ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill"))
                .font(.caption.weight(.bold))
            Text(isNeutral ? "Settled" : abs(net).formatted(.currency(code: currencyCode)))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(isNeutral ? Color.green : (isPositive ? Color.green : Color.red))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill((isNeutral ? Color.green : (isPositive ? Color.green : Color.red)).opacity(0.12))
        )
    }

    private func stat(label: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value.formatted(.currency(code: currencyCode)))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupHeaderStatus: View {
    let settlementCount: Int

    var body: some View {
        HStack(spacing: 5) {
            if settlementCount == 0 {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color { settlementCount == 0 ? .green : .orange }
    private var label: String {
        settlementCount == 0 ? "Settled" : "\(settlementCount) to settle"
    }
}

// MARK: - Flow layout

/// Wraps subviews onto multiple lines when they exceed the proposed width.
/// Each line stretches to its tallest subview.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = arrange(subviews: subviews, in: width)
        return CGSize(width: result.maxX, height: result.maxY)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrange(subviews: subviews, in: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(
        subviews: Subviews,
        in width: CGFloat
    ) -> (frames: [CGRect], maxX: CGFloat, maxY: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, maxX, y + lineHeight)
    }
}

private struct InviteShareWrapper: Identifiable {
    let url: URL
    var id: URL { url }
    init(_ url: URL) { self.url = url }
}
