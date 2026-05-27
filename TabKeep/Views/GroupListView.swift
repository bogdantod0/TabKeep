import SwiftUI

struct GroupListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onCreateTap: () -> Void

    @State private var archivedExpanded = false
    @State private var hero: HeroSnapshot = .empty

    var body: some View {
        Group {
            if store.activeGroups.isEmpty && store.archivedGroups.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: heroKey) {
            hero = await store.heroSnapshot()
        }
    }

    private struct HeroDependencyKey: Hashable {
        let groupsHash: Int
        let defaultCurrency: String
        let userMatchKey: String
    }

    private var heroKey: HeroDependencyKey {
        HeroDependencyKey(
            groupsHash: store.groups.hashValue,
            defaultCurrency: store.defaultCurrencyCode,
            userMatchKey: store.user.matchKey
        )
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                BalanceHeroCard(snapshot: hero)
                    .padding(.bottom, 4)

                ForEach(store.activeGroups) { group in
                    NavigationLink(value: GroupsRoute.group(id: group.id)) {
                        GroupCard(
                            group: group,
                            userBalance: store.userBalance(in: group),
                            settlementCount: store.settlements(forGroup: group.id).count
                        )
                    }
                    .buttonStyle(CardPressStyle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            let gid = group.id
                            Task { try? await store.archiveGroup(id: gid) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(AppTheme.warning)
                    }
                }

                if !store.archivedGroups.isEmpty {
                    ArchivedSection(
                        groups: store.archivedGroups,
                        isExpanded: $archivedExpanded
                    )
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, BottomTabBar.height + 24)
        }
        .refreshable {
            await store.foregroundRefresh(force: true)
            await store.retryPendingRates()
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
    }

    private var emptyState: some View {
        CompactEmptyState(
            icon: "person.3.fill",
            title: "No groups yet",
            description: "Create your first group to start splitting expenses."
        ) {
            Button {
                onCreateTap()
            } label: {
                Text("New Group")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(AppTheme.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("emptyNewGroupButton")
        }
    }
}

// MARK: - Balance hero

private struct BalanceHeroCard: View {
    let snapshot: HeroSnapshot

    private static let amountInk = Color(red: 236.0 / 255.0, green: 253.0 / 255.0, blue: 247.0 / 255.0)
    private static let owedColor = Color(red: 74.0 / 255.0, green: 222.0 / 255.0, blue: 128.0 / 255.0)
    private static let owesColor = Color(red: 252.0 / 255.0, green: 165.0 / 255.0, blue: 165.0 / 255.0)
    private static let bgTop = Color(red: 16.0 / 255.0, green: 37.0 / 255.0, blue: 50.0 / 255.0)
    private static let bgBottom = Color(red: 8.0 / 255.0, green: 24.0 / 255.0, blue: 32.0 / 255.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tagPill
            amountRow
                .padding(.top, 6)
            Text(subText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 2)
            splits
                .padding(.top, 10)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            // Subtle teal glow — kept in background so it doesn't pad layout.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [AppTheme.accent.opacity(0.32), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 110
                    )
                )
                .frame(width: 180, height: 180)
                .offset(x: 60, y: -70)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .background(
            LinearGradient(
                colors: [Self.bgTop, Self.bgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Self.bgBottom.opacity(0.4), radius: 14, x: 0, y: 10)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var tagPill: some View {
        Text(tagText)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
    }

    private var amountRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(formattedNet)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Self.amountInk)
            Text(snapshot.displayCurrency)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var splits: some View {
        HStack(spacing: 8) {
            splitTile(
                label: "You're owed",
                amount: snapshot.owedToUser,
                prefix: snapshot.owedToUser > 0 ? "+" : "",
                color: Self.owedColor
            )
            splitTile(
                label: "You owe",
                amount: snapshot.userOwes,
                prefix: snapshot.userOwes > 0 ? "−" : "",
                color: Self.owesColor
            )
        }
    }

    private func splitTile(label: String, amount: Decimal, prefix: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))
            Text(prefix + amount.formatted(.currency(code: snapshot.displayCurrency)))
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.05), lineWidth: 1)
                )
        )
    }

    private var tagText: String {
        if snapshot.groupCount == 0 { return "Welcome" }
        let plural = snapshot.groupCount == 1 ? "group" : "groups"
        var t = "Net across \(snapshot.groupCount) \(plural)"
        if snapshot.pendingCount > 0 { t += " · approx" }
        return t
    }

    private var subText: String {
        if snapshot.groupCount == 0 { return "Create a group to start splitting" }
        if snapshot.unsettledCount == 0 { return "Everything is settled" }
        let plural = snapshot.unsettledCount == 1 ? "group needs settling" : "groups need settling"
        return "\(snapshot.unsettledCount) \(plural)"
    }

    private var formattedNet: String {
        let net = snapshot.netInDefault
        let absValue = net < 0 ? -net : net
        let prefix: String
        if net > 0 { prefix = "+" }
        else if net < 0 { prefix = "−" }
        else { prefix = "" }
        return prefix + absValue.formatted(.currency(code: snapshot.displayCurrency).presentation(.standard))
    }

    private var accessibilitySummary: String {
        let net = snapshot.netInDefault
        if net == 0 {
            return "Net balance: zero. \(subText)."
        }
        return "Net balance: \(formattedNet). \(subText)."
    }
}

// MARK: - Group card

private struct GroupCard: View {
    let group: ExpenseGroup
    let userBalance: Decimal?
    let settlementCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            emojiTile
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(metaLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            balanceColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
        .shadow(
            color: AppTheme.cardShadowColor,
            radius: AppTheme.cardShadowRadius,
            x: 0,
            y: AppTheme.cardShadowYOffset
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var metaLabel: String {
        let count = group.members.lazy.filter { $0.archivedAt == nil }.count
        let plural = count == 1 ? "" : "s"
        return "\(count) member\(plural) · \(group.currencyCode)"
    }

    private var emojiTile: some View {
        EmojiText(emoji: group.emoji ?? "👥", size: 22)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.12))
            )
    }

    @ViewBuilder
    private var balanceColumn: some View {
        if let balance = userBalance {
            if balance == 0 {
                settledPill
            } else {
                balanceLabel(balance)
            }
        } else {
            // Fallback when the user isn't a named member of this group.
            StatusBadge(settlementCount: settlementCount)
        }
    }

    private var settledPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
            Text("Settled")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(AppTheme.success)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppTheme.success.opacity(0.14)))
    }

    private func balanceLabel(_ balance: Decimal) -> some View {
        let isPositive = balance > 0
        let absValue = balance < 0 ? -balance : balance
        let prefix = isPositive ? "+" : "−"
        let color: Color = isPositive ? AppTheme.success : AppTheme.danger
        return VStack(alignment: .trailing, spacing: 2) {
            Text(prefix + absValue.formatted(.currency(code: group.currencyCode)))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
            Text(isPositive ? "You're owed" : "You owe")
                .font(.caption2.weight(.semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = [group.name, metaLabel]
        if let bal = userBalance {
            if bal == 0 {
                parts.append("settled")
            } else if bal > 0 {
                parts.append("you're owed \(bal.formatted(.currency(code: group.currencyCode)))")
            } else {
                parts.append("you owe \((-bal).formatted(.currency(code: group.currencyCode)))")
            }
        } else if settlementCount > 0 {
            parts.append("\(settlementCount) payment\(settlementCount == 1 ? "" : "s") to settle")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Status badge

private struct StatusBadge: View {
    let settlementCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: settlementCount == 0
                  ? "checkmark.seal.fill"
                  : "exclamationmark.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityLabel(accessibilityText)
    }

    private var color: Color {
        settlementCount == 0 ? AppTheme.success : AppTheme.warning
    }
    private var label: String {
        settlementCount == 0 ? "Settled" : "\(settlementCount) to settle"
    }
    private var accessibilityText: String {
        settlementCount == 0
            ? "Settled"
            : "\(settlementCount) payment\(settlementCount == 1 ? "" : "s") to settle"
    }
}

// MARK: - Archived section

private struct ArchivedSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groups: [ExpenseGroup]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(.secondary)
                    Text("Archived")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(groups.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        NavigationLink(value: GroupsRoute.group(id: group.id)) {
                            ArchivedRow(group: group)
                        }
                        .buttonStyle(CardPressStyle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                let gid = group.id
                                Task { try? await store.unarchiveGroup(id: gid) }
                            } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }
                            .tint(AppTheme.accent)
                        }
                    }
                }
            }
        }
    }
}

private struct ArchivedRow: View {
    let group: ExpenseGroup

    var body: some View {
        HStack(spacing: 12) {
            EmojiText(emoji: group.emoji ?? "👥", size: 22)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(archivedAgo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .opacity(0.85)
    }

    private var archivedAgo: String {
        if let when = group.archivedAt {
            return "Archived \(when.formatted(.relative(presentation: .named)))"
        }
        return "Archived"
    }
}

// MARK: - Press style

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Create Group Sheet

struct CreateGroupSheet: View {
    enum Mode: Equatable {
        case create
        case edit(groupID: UUID)

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    var onCreated: (UUID) -> Void = { _ in }
    var onSaved: () -> Void = {}

    @State private var name = ""
    @State private var emoji = "✈️"
    @State private var currencyCode = ""
    @State private var pendingMembers: [PendingMember] = []
    @State private var showingCurrencyPicker = false
    @State private var showingEmojiPicker = false
    @State private var didSeed = false
    @State private var isCommitting = false
    @State private var commitError: String?
    @State private var lockedMemberInfo: LockedMemberInfo?

    private struct LockedMemberInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @FocusState private var focus: Field?
    private enum Field: Hashable { case name }

    struct PendingMember: Identifiable, Hashable {
        let id = UUID()
        /// Set for chips bound to existing members in edit mode; the save
        /// path diffs these IDs against the live group to detect removals.
        /// `nil` for the create-mode self-seeded "you" chip, which is
        /// display-only — the host membership itself is created server-side
        /// inside `AppStore.createGroup`.
        let existingID: UUID?
        var name: String
        var emoji: String
        var isYou: Bool = false
        /// True when this member is referenced by an expense or payment in
        /// the live group. Locked members can't be removed without first
        /// settling or deleting the entries that reference them — the chip
        /// renders a tappable "In use" pill that opens an explanation.
        var isLocked: Bool = false

        init(
            existingID: UUID? = nil,
            name: String,
            emoji: String,
            isYou: Bool = false,
            isLocked: Bool = false
        ) {
            self.existingID = existingID
            self.name = name
            self.emoji = emoji
            self.isYou = isYou
            self.isLocked = isLocked
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    heroIdentity
                    currencySummary
                    if mode.isEditing {
                        membersCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(AppTheme.sheetBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focus = nil }
            .navigationTitle(mode.isEditing ? "Edit Group" : "New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                stickyCTA
            }
            .onAppear {
                if currencyCode.isEmpty { currencyCode = store.defaultCurrencyCode }
                seedFromExistingGroupIfNeeded()
                seedSelfMemberIfNeeded()
                didSeed = true
            }
            .task {
                try? await Task.sleep(for: .milliseconds(200))
                focus = .name
            }
            .presentationDetents([.large])
            .presentationCornerRadius(32)
            .sheet(isPresented: $showingEmojiPicker) {
                EmojiPickerSheet(selection: $emoji, category: .travelAndOutdoors)
            }
            .sheet(isPresented: $showingCurrencyPicker) {
                AllCurrenciesSheet(selected: currencyCode) { picked in
                    currencyCode = picked
                }
            }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func requestCreate() {
        focus = nil
        commit()
    }

    // MARK: Hero + sections

    private var heroIdentity: some View {
        VStack(spacing: 14) {
            Button {
                showingEmojiPicker = true
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(AppTheme.accent.opacity(0.10), lineWidth: 1)
                        .frame(width: 96, height: 96)

                    ZStack(alignment: .bottomTrailing) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.accent.opacity(0.28), AppTheme.accent.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1))
                            Text(emoji.isEmpty ? "✈️" : emoji)
                                .font(.system(size: 40))
                        }
                        .frame(width: 80, height: 80)
                        .shadow(color: AppTheme.accent.opacity(0.18), radius: 10, x: 0, y: 5)

                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .background(Capsule().fill(AppTheme.accent))
                        .overlay(Capsule().strokeBorder(AppTheme.pageBackground, lineWidth: 3))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Group emoji")
            .accessibilityValue(emoji.isEmpty ? "None" : emoji)

            TextField("Group name", text: $name)
                .multilineTextAlignment(.center)
                .font(.subheadline.weight(.semibold))
                .focused($focus, equals: .name)
                .submitLabel(.done)
                .onSubmit { focus = nil }
                .accessibilityIdentifier("groupNameField")
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            focus == .name ? AppTheme.accent : AppTheme.borderHairline,
                            lineWidth: focus == .name ? 1.5 : 1
                        )
                )
                .shadow(
                    color: AppTheme.accent.opacity(focus == .name ? 0.18 : 0),
                    radius: 6,
                    x: 0,
                    y: 0
                )
                .animation(.easeInOut(duration: 0.15), value: focus)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    private var currencySummary: some View {
        Button {
            showingCurrencyPicker = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Currency")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    HStack(spacing: 6) {
                        Text(currencyCode)
                            .font(.subheadline.weight(.semibold))
                        Text("· \(SupportedCurrencies.displayName(for: currencyCode))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accent.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newGroupCurrencyButton")
    }

    private var stickyCTA: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            if let commitError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.danger)
                    Text(commitError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Button {
                requestCreate()
            } label: {
                HStack(spacing: 8) {
                    if isCommitting { ProgressView().tint(.white) }
                    Text(mode.isEditing ? (isCommitting ? "Saving…" : "Save") : (isCommitting ? "Creating…" : "Create Group"))
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill((canSubmit && !isCommitting) ? AppTheme.accent : AppTheme.accent.opacity(0.35))
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .disabled(!canSubmit || isCommitting)
            .buttonStyle(.plain)
            .accessibilityIdentifier(mode.isEditing ? "editGroupSaveButton" : "createGroupConfirm")
        }
        .background(AppTheme.sheetBackground)
    }

    /// True when the user is allowed to remove or add members in this sheet.
    /// Create-mode is always permissive (the user is implicitly the host of a
    /// group they're creating). Edit-mode defers to `AppStore.isHost(of:)`,
    /// which defaults to `true` for any group the local user could plausibly
    /// own (local-only, pre-ownerUserID, host-on-shared).
    private var canManageMembers: Bool {
        switch mode {
        case .create:        return true
        case .edit(let id):  return store.isHost(of: id)
        }
    }

    private var membersCard: some View {
        cardFrame(
            title: "Members",
            trailing: pendingMembers.isEmpty ? nil : "\(pendingMembers.count)"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !mode.isEditing {
                    Text("You'll be the first member. Invite people via a share link after creating the group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !pendingMembers.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(pendingMembers) { m in
                            PendingMemberRow(
                                member: m,
                                canRemove: canManageMembers,
                                onRemove: {
                                    withAnimation(.snappy) {
                                        pendingMembers.removeAll { $0.id == m.id }
                                    }
                                },
                                onExplainLock: {
                                    lockedMemberInfo = makeLockedMemberInfo(for: m)
                                }
                            )
                        }
                    }
                }
                if canManageMembers {
                    if mode.isEditing && pendingMembers.contains(where: \.isLocked) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(AppTheme.accent)
                            Text("Some members are in expenses or payments. Tap the lock to learn how to remove them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.accent)
                        Text("Only the host can change members. Use Leave group on the group screen to exit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .alert(
            lockedMemberInfo?.title ?? "",
            isPresented: Binding(
                get: { lockedMemberInfo != nil },
                set: { if !$0 { lockedMemberInfo = nil } }
            ),
            presenting: lockedMemberInfo
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func cardFrame<Content: View>(
        title: String,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
    }

    /// Pre-populate the user as the first pending member so a new group
    /// always starts with the device owner already in it. Only runs on first
    /// appear, only in create mode. Falls back to "Me" / default emoji for
    /// anonymous users who haven't completed onboarding yet — they can rename
    /// the chip before saving if they want.
    private func seedSelfMemberIfNeeded() {
        guard !mode.isEditing, !didSeed, pendingMembers.isEmpty else { return }
        let seedName = store.user.hasName ? store.user.name : "Me"
        let glyph = store.user.emoji.isEmpty ? Member.defaultEmoji : store.user.emoji
        pendingMembers.append(PendingMember(
            name: seedName,
            emoji: glyph,
            isYou: true
        ))
    }

    /// Edit-mode only: seed name/emoji/currency/members from the live group
    /// the first time the sheet appears. Filters to active members; archived
    /// members stay in the data so historical expenses/payments still resolve
    /// their names but are hidden from this editor.
    private func seedFromExistingGroupIfNeeded() {
        guard case .edit(let id) = mode, !didSeed, let g = store.group(id: id) else { return }
        name = g.name
        emoji = g.emoji ?? "✈️"
        currencyCode = g.currencyCode
        let userKey = store.user.matchKey
        let serverID = store.user.serverID
        for m in g.members where m.archivedAt == nil {
            // Prefer server-side identity (matches even after a rename)
            // over the name-based fallback used for anonymous / unsynced users.
            let matchesUser: Bool
            if let myID = serverID, let theirID = m.userID {
                matchesUser = (myID == theirID)
            } else {
                matchesUser = store.user.hasName
                    && m.name.trimmingCharacters(in: .whitespaces).lowercased() == userKey
            }
            let referencedByExpense = g.expenses.contains {
                $0.payerID == m.id || $0.participantIDs.contains(m.id)
            }
            let referencedByPayment = (g.payments ?? []).contains {
                $0.fromMemberID == m.id || $0.toMemberID == m.id
            }
            pendingMembers.append(PendingMember(
                existingID: m.id,
                name: m.name,
                emoji: m.emoji,
                isYou: matchesUser,
                isLocked: referencedByExpense || referencedByPayment
            ))
        }
    }

    private func makeLockedMemberInfo(for m: PendingMember) -> LockedMemberInfo {
        guard case .edit(let id) = mode,
              let g = store.group(id: id),
              let memberID = m.existingID else {
            return LockedMemberInfo(
                title: "\(m.name) can't be removed",
                message: "They're part of this group's expenses or payments. Settle or delete those entries first."
            )
        }
        let expenseCount = g.expenses.filter {
            $0.payerID == memberID
                || $0.participantIDs.contains(memberID)
                || ($0.payments ?? []).contains(where: { $0.memberID == memberID })
                || ($0.shares ?? []).contains(where: { $0.memberID == memberID })
        }.count
        let paymentCount = (g.payments ?? []).filter {
            $0.fromMemberID == memberID || $0.toMemberID == memberID
        }.count
        var parts: [String] = []
        if expenseCount > 0 { parts.append("\(expenseCount) \(expenseCount == 1 ? "expense" : "expenses")") }
        if paymentCount > 0 { parts.append("\(paymentCount) \(paymentCount == 1 ? "payment" : "payments")") }
        let detail = parts.isEmpty ? "this group's activity" : parts.joined(separator: " and ")
        return LockedMemberInfo(
            title: "\(m.name) can't be removed",
            message: "They're part of \(detail). To remove this member, first delete or reassign those entries on the Expenses and Balances tabs."
        )
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let finalEmoji = emoji.isEmpty ? "✈️" : emoji
        let capturedMode = mode
        let capturedMembers = pendingMembers
        let capturedCurrency = currencyCode
        let onCreated = onCreated
        let onSaved = onSaved
        let store = store
        isCommitting = true
        commitError = nil
        Task { @MainActor in
            defer { isCommitting = false }
            switch capturedMode {
            case .create:
                let newID: UUID
                do {
                    newID = try await store.createGroup(
                        name: trimmed,
                        emoji: finalEmoji,
                        currencyCode: capturedCurrency
                    )
                } catch {
                    commitError = "Couldn't create group. Try again."
                    return
                }
                onCreated(newID)
                dismiss()

            case .edit(let id):
                do {
                    try await store.updateGroup(id: id, name: trimmed, emoji: finalEmoji, currencyCode: capturedCurrency)
                } catch AppStoreError.groupHasPayments {
                    commitError = "Can't change currency while the group has recorded payments. Delete the payments first."
                    return
                } catch {
                    commitError = "Couldn't save group details. Try again."
                    return
                }
                var failedNames: [String] = []
                if let g = store.group(id: id) {
                    let pendingExistingIDs = Set(capturedMembers.compactMap(\.existingID))
                    // Skip already-archived members — re-archiving would just
                    // re-stamp archivedAt for no reason. Only archive active
                    // members that the user removed from the chip list.
                    for m in g.members
                        where m.archivedAt == nil && !pendingExistingIDs.contains(m.id)
                    {
                        do {
                            try await store.removeMember(fromGroup: id, memberID: m.id)
                        } catch {
                            failedNames.append(m.name)
                        }
                    }
                }
                if !failedNames.isEmpty {
                    let joined = failedNames.joined(separator: ", ")
                    commitError = "Saved, but couldn't update: \(joined)."
                    return
                }
                onSaved()
                dismiss()
            }
        }
    }
}

// MARK: - Pending member chip

private struct PendingMemberRow: View {
    let member: CreateGroupSheet.PendingMember
    let canRemove: Bool
    var onRemove: () -> Void
    var onExplainLock: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(emoji: member.emoji, size: 32)
            Text(member.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if member.isYou {
                YouBadge()
            }
            Spacer(minLength: 8)
            if member.isLocked {
                Button(action: onExplainLock) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                        Text("In use")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(member.name) is in expenses or payments. Tap to learn more.")
            } else if canRemove && !member.isYou {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(member.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.pageBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
        )
    }
}

/// Small capsule pill used on member rows to mark the device owner.
struct YouBadge: View {
    var body: some View {
        Text("You")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(AppTheme.accent.opacity(0.18)))
            .foregroundStyle(AppTheme.accent)
            .accessibilityLabel("You")
    }
}
