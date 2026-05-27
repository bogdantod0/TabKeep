import SwiftUI

struct RootTabView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedTab: BottomTabBar.Tab = .groups
    @State private var groupsPath: [GroupsRoute] = []
    @State private var addSheet: AddSheet?
    @State private var postCreateInviteGroupID: UUID?

    private enum AddSheet: Identifiable {
        case createGroup
        case addExpense(groupID: UUID)

        var id: String {
            switch self {
            case .createGroup: return "createGroup"
            case .addExpense(let id): return "addExpense-\(id.uuidString)"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            tabContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: isTabBarHidden ? 0 : BottomTabBar.height)
                }
            if !isTabBarHidden {
                LinearGradient(
                    colors: [
                        AppTheme.pageBackground.opacity(0),
                        AppTheme.pageBackground
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: BottomTabBar.height + 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if !isTabBarHidden {
                BottomTabBar(
                    selection: selectedTab,
                    onSelect: handleTabTap
                )
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !isTabBarHidden && selectedTab == .groups {
                floatingAddGroupButton
            }
            undoOverlay
            backfillOverlay
            conflictOverlay
            inviteToastOverlay
            inviteErrorOverlay
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .animation(.snappy, value: store.pendingDeletion?.id)
        .animation(.snappy, value: store.pendingBackfill?.id)
        .animation(.snappy, value: isTabBarHidden)
        .animation(.snappy, value: store.lastJoinedGroupID)
        .animation(.snappy, value: store.inviteErrorBanner?.id)
        .sheet(item: $addSheet) { sheet in
            Group {
                switch sheet {
                case .createGroup:
                    CreateGroupSheet(mode: .create, onCreated: { id in
                        addSheet = nil
                        postCreateInviteGroupID = id
                    })
                case .addExpense(let id):
                    AddExpenseView(groupID: id)
                }
            }
        }
        .sheet(item: Binding(
            get: { postCreateInviteGroupID.map(IdentifiableUUID.init) },
            set: { _ in postCreateInviteGroupID = nil }
        )) { wrapper in
            PostGroupCreationInviteView(groupID: wrapper.id) { id in
                postCreateInviteGroupID = nil
                selectedTab = .groups
                groupsPath = [.group(id: id)]
            }
        }
        .sheet(item: Binding(
            get: { store.pendingInviteConfirm },
            set: { _ in store.pendingInviteConfirm = nil }
        )) { confirm in
            InviteConfirmSheet(confirm: confirm)
        }
        .onChange(of: store.lastJoinedGroupID) { _, newID in
            guard let newID else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedTab = .groups
                groupsPath = [.group(id: newID)]
            }
        }
        .task {
            // Cold-path: a deferred deep link captured during install
            // (and persisted to v16 PersistedState as pendingInviteToken)
            // is consumed here, after onboarding completes and RootTabView
            // mounts for the first time.
            if let pending = store.pendingInviteToken {
                await store.handleIncomingInvite(token: pending, isColdPath: true)
            }
        }
        // The detached invite-bootstrap Task in TabKeepApp.task can finish
        // AFTER RootTabView mounts — e.g., user taps a Grovs universal link
        // on a fresh install, completes onboarding faster than the SDK
        // surfaces the captured payload, and `.task` above reads a still-nil
        // token. Without this observer the join wouldn't fire until the next
        // scenePhase = .active. handleIncomingInvite is re-entrancy-guarded.
        .onChange(of: store.pendingInviteToken) { _, newToken in
            guard let newToken else { return }
            Task { await store.handleIncomingInvite(token: newToken, isColdPath: true) }
        }
    }

    @ViewBuilder
    private var undoOverlay: some View {
        if let pending = store.pendingDeletion {
            UndoSnackbar(
                pending: pending,
                onUndo: { store.undoPendingDeletion() },
                onCommit: { Task { await store.commitPendingDeletion() } }
            )
            .padding(.bottom, BottomTabBar.height + 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var backfillOverlay: some View {
        if let pending = store.pendingBackfill {
            BackfillSnackbar(
                pending: pending,
                onUndo: { Task { await store.undoPendingBackfill() } },
                onDismiss: { store.dismissPendingBackfill() }
            )
            .padding(.bottom, BottomTabBar.height + 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var conflictOverlay: some View {
        if !store.conflictBanners.isEmpty {
            ConflictBannerStack()
                .padding(.bottom, BottomTabBar.height + 56)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var inviteToastOverlay: some View {
        if let id = store.lastJoinedGroupID, let g = store.group(id: id) {
            InviteToast(
                groupName: g.name,
                groupEmoji: g.emoji,
                onDismiss: { store.lastJoinedGroupID = nil }
            )
            .padding(.bottom, BottomTabBar.height + 80)
        }
    }

    @ViewBuilder
    private var inviteErrorOverlay: some View {
        if let banner = store.inviteErrorBanner {
            Text(banner.message)
                .font(.subheadline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.red.opacity(0.92), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    store.inviteErrorBanner = nil
                }
        }
    }

    private var floatingAddGroupButton: some View {
        Button {
            addSheet = .createGroup
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(AppTheme.accent.gradient)
                )
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20)
        .padding(.bottom, BottomTabBar.height + 12)
        .accessibilityIdentifier("groupListAddGroupButton")
        .accessibilityLabel("New group")
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(true)
    }

    private var isTabBarHidden: Bool {
        guard selectedTab == .groups else { return false }
        switch groupsPath.last {
        case .group, .expense: return true
        case .none:            return false
        }
    }

    private func handleTabTap(_ tap: BottomTabBar.Tab) {
        if tap == selectedTab && tap == .groups {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                groupsPath.removeAll()
            }
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            selectedTab = tap
        }
    }

    private func resolveAddSheet() -> AddSheet {
        if selectedTab == .groups {
            for route in groupsPath.reversed() {
                switch route {
                case .group(let id), .expense(let id, _):
                    return .addExpense(groupID: id)
                }
            }
        }
        return .createGroup
    }

    private func selectGroup(_ id: UUID) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            selectedTab = .groups
            groupsPath = [.group(id: id)]
        }
    }

    private var tabContent: some View {
        ZStack {
            NavigationStack {
                DashboardView(
                    onSelectGroup: selectGroup,
                    onCreateGroup: { addSheet = .createGroup }
                )
            }
            .opacity(selectedTab == .dashboard ? 1 : 0)
            .allowsHitTesting(selectedTab == .dashboard)
            .accessibilityHidden(selectedTab != .dashboard)

            NavigationStack(path: $groupsPath) {
                GroupListView(
                    onCreateTap: { addSheet = .createGroup }
                )
                    .navigationDestination(for: GroupsRoute.self) { route in
                        switch route {
                        case .group(let id):
                            GroupDetailView(groupID: id)
                        case .expense(let gid, let eid):
                            EditExpenseView(groupID: gid, expenseID: eid)
                        }
                    }
            }
            .opacity(selectedTab == .groups ? 1 : 0)
            .allowsHitTesting(selectedTab == .groups)
            .accessibilityHidden(selectedTab != .groups)
            .onChange(of: store.pendingNavigation) { _, _ in
                guard let route = store.consumePendingNavigation() else { return }
                if selectedTab != .groups {
                    selectedTab = .groups
                }
                if case .expense(let gid, _) = route {
                    groupsPath = [.group(id: gid), route]
                } else {
                    groupsPath = [route]
                }
            }
            .onChange(of: groupsPath) { oldValue, newValue in
                // Mirror GroupDetailView's on-enter refresh: when the user
                // pops all the way back to the group list, the cards' user
                // balances / settlement counts are stale relative to other
                // groups changed elsewhere (other devices, push-driven
                // edits). Refresh every group so the cards reflect the
                // current state without requiring a manual pull-to-refresh.
                if !oldValue.isEmpty && newValue.isEmpty {
                    Task {
                        await store.foregroundRefresh()
                        await store.retryPendingRates()
                    }
                }
            }

            NavigationStack {
                ActivityView(onSelectGroup: selectGroup)
            }
            .opacity(selectedTab == .activity ? 1 : 0)
            .allowsHitTesting(selectedTab == .activity)
            .accessibilityHidden(selectedTab != .activity)

            NavigationStack {
                SettingsView()
            }
            .opacity(selectedTab == .settings ? 1 : 0)
            .allowsHitTesting(selectedTab == .settings)
            .accessibilityHidden(selectedTab != .settings)
        }
    }
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}
