import SwiftUI
import PhotosUI
import UIKit

enum PendingReceipt: Identifiable {
    case existing(ReceiptAttachment)
    case new(id: UUID, data: Data)

    var id: UUID {
        switch self {
        case .existing(let r): return r.id
        case .new(let id, _): return id
        }
    }
}

struct ExpenseFormContent: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: ExpenseEditorModel

    private func isYou(_ member: Member) -> Bool {
        guard store.user.hasName else { return false }
        return member.name.trimmingCharacters(in: .whitespaces).lowercased() == store.user.matchKey
    }


    @State private var showingAddDialog = false
    @State private var showingCamera = false
    @State private var showingPhotosPicker = false
    @State private var showingCurrencyPicker = false
    @State private var showingDateSheet = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var viewerPayload: ViewerPayload? = nil
    @FocusState private var amountFocused: Bool
    /// Hero font size for the amount + currency block. Held as @State and
    /// recomputed via .onChange so each keystroke triggers a re-layout
    /// (a computed property based on `displayedAmount.count` doesn't always
    /// invalidate the TextField in real time when `.fixedSize` is involved).
    @State private var heroFontSize: CGFloat = 48
    @State private var showingMultiPayerSheet = false
    @State private var showingCustomCategoryAlert = false
    @State private var customCategoryName = ""

    enum SplitMode: String, CaseIterable, Hashable {
        case equal, amount, percent
        var label: String {
            switch self {
            case .equal:   return "Equal"
            case .amount:  return "Amount"
            case .percent: return "Percent"
            }
        }

        /// True when the row has an editable value input that should
        /// receive row taps instead of toggling include/exclude.
        var allowsValueFocus: Bool {
            switch self {
            case .equal:               return false
            case .amount, .percent:    return true
            }
        }
    }
    @State private var splitMode: SplitMode = .equal
    @State private var memberAmounts: [UUID: String] = [:]
    @State private var memberPercents: [UUID: String] = [:]
    /// Members the user has explicitly typed an amount into. The remainder
    /// is auto-distributed across everyone else in `.amount` mode whenever a
    /// value, participant list, or expense total changes.
    @State private var manuallyEditedAmountIDs: Set<UUID> = []
    @State private var manuallyEditedPercentIDs: Set<UUID> = []
    /// Set true when `.onAppear` seeds `memberAmounts` from the saved
    /// `initialShares`. The subsequent `.onChange(of: splitMode)` then
    /// consumes the flag and skips the auto-redistribute that would
    /// otherwise overwrite the seeded values with an even split.
    @State private var didSeedFromInitialShares: Bool = false

    @State private var displayedAmount: String = ""

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    /// Strips group separators from a user-typed string so it round-trips
    /// through `Decimal(string:)` the same way the rest of the app expects.
    private static func normalizeAmount(_ raw: String) -> String {
        let grouping = Locale.current.groupingSeparator ?? ","
        let decimal = Locale.current.decimalSeparator ?? "."
        var out = raw.replacingOccurrences(of: grouping, with: "")
        if decimal != "." {
            out = out.replacingOccurrences(of: decimal, with: ".")
        }
        return out
    }

    /// Turns a normalized string like "1234.5" into the displayed string
    /// "1,234.5" using the current locale's grouping and decimal separators.
    private static func formatAmountForDisplay(_ normalized: String) -> String {
        if normalized.isEmpty { return "" }
        let hasTrailingSeparator = normalized.hasSuffix(".")
        guard let decimal = Decimal(string: normalized) else { return normalized }
        let formatted = amountFormatter.string(from: NSDecimalNumber(decimal: decimal)) ?? normalized
        return hasTrailingSeparator && !formatted.contains(Locale.current.decimalSeparator ?? ".")
            ? formatted + (Locale.current.decimalSeparator ?? ".")
            : formatted
    }

    static let maxReceipts = 10

    private var remainingReceiptSlots: Int {
        max(0, Self.maxReceipts - model.pendingReceipts.count)
    }

    var body: some View {
        VStack(spacing: 14) {
            primarySection

            // Pickable members only — archived members and ghost members
            // (account-deleted, userID == nil) shouldn't appear in the
            // payer/participant pickers. Their UUIDs still resolve names
            // for historical expenses elsewhere.
            let allMembers = model.group?.members ?? []
            let members = allMembers.pickable(currentUserServerID: model.currentUserServerID)
            if !members.isEmpty {
                receiptsCard
                breakdownSection(members: members)
            } else {
                dateOnlySection
                membersEmpty
            }
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $showingCurrencyPicker) {
            ExpenseCurrencyPickerSheet(selected: $model.currencyCode, tint: model.accent)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    amountFocused = false
                    // Per-row share TextFields (.amount / .percent split modes)
                    // don't share `amountFocused`, so resign whichever input
                    // currently has focus.
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            if let seed = model.initialShares, !seed.isEmpty {
                // Populate memberAmounts/Percents BEFORE flipping splitMode
                // so the change handler observes the seeded values. Mark
                // each seeded member as manually-edited so any redistribute
                // that does sneak in (from amountText/participantIDs change
                // handlers) leaves them alone.
                let kind = model.initialSplitKind   // "amount", "percent", or nil
                let total = model.amount > 0 ? model.amount : Decimal(1)
                if kind == "percent" {
                    for share in seed {
                        // share.amount is the per-member amount; recover
                        // the original percent: percent = amount/total*100.
                        let pct = (share.amount / total) * Decimal(100)
                        memberPercents[share.memberID] = plainPercentString(pct.roundedTo2())
                        manuallyEditedPercentIDs.insert(share.memberID)
                    }
                    model.participantIDs = Set(seed.map(\.memberID))
                    didSeedFromInitialShares = true
                    splitMode = .percent
                } else {
                    for share in seed {
                        memberAmounts[share.memberID] = plainAmountString(share.amount)
                        manuallyEditedAmountIDs.insert(share.memberID)
                    }
                    model.participantIDs = Set(seed.map(\.memberID))
                    didSeedFromInitialShares = true
                    splitMode = .amount
                }
            }
            recomputeSplitValidity()
            model.shares = currentShares()
            model.splitKind = Self.splitKindString(for: splitMode)
        }
        .onChange(of: splitMode) { _, newMode in
            // Switching back to .amount: clear any prior manual edits so the
            // column auto-distributes evenly until the user types something.
            //
            // EXCEPTION: this assignment came from `.onAppear`'s initialShares
            // seed flow. Redistributing here would overwrite the seeded
            // values with an even split. Consume the one-shot flag and skip.
            if newMode == .amount {
                if didSeedFromInitialShares {
                    didSeedFromInitialShares = false
                } else {
                    manuallyEditedAmountIDs.removeAll()
                    redistributeAmountSplit()
                }
            } else if newMode == .percent {
                if didSeedFromInitialShares {
                    didSeedFromInitialShares = false
                } else {
                    manuallyEditedPercentIDs.removeAll()
                    redistributePercentSplit()
                }
            }
            recomputeSplitValidity()
            model.shares = currentShares()
            model.splitKind = Self.splitKindString(for: newMode)
        }
        .onChange(of: model.amountText) { _, _ in
            // amountText doesn't affect percent splits (which always sum to
            // 100), but it does affect amount splits — redistribute there.
            redistributeAmountSplit()
            // Multi-payer credit side: rescale stored payments so they keep
            // summing to the new total, without forcing the user to re-open
            // the sheet.
            rescalePaymentsForNewTotal()
            recomputeSplitValidity()
            model.shares = currentShares()
        }
        .onChange(of: model.participantIDs) { _, newIDs in
            // Drop manual edits for members no longer included, then
            // redistribute whichever split is active.
            manuallyEditedAmountIDs = manuallyEditedAmountIDs.intersection(newIDs)
            manuallyEditedPercentIDs = manuallyEditedPercentIDs.intersection(newIDs)
            redistributeAmountSplit()
            redistributePercentSplit()
            recomputeSplitValidity()
            model.shares = currentShares()
        }
        .onChange(of: memberAmounts)        { _, _ in recomputeSplitValidity(); model.shares = currentShares() }
        .onChange(of: memberPercents)       { _, _ in recomputeSplitValidity(); model.shares = currentShares() }
        .onChange(of: model.category) { _, _ in
            Haptics.selection()
        }
    }

    // MARK: - Category picker options

    private var categoryPickerOptions: [ExpenseCategory] {
        var picked = ExpenseCategory.availableCategories(in: model.group?.expenses ?? [])
        if !picked.contains(model.category) {
            picked.append(model.category)
        }
        return picked
    }

    // MARK: - Split validation

    private var splitValidationError: String? {
        switch splitMode {
        case .equal:
            return nil
        case .amount:
            guard model.amount > 0 else { return nil }
            let delta = abs(model.amount - enteredAmountsTotal())
            if delta > Decimal(0.01) {
                return "Shares don't add up to \(model.amount.formatted(.currency(code: model.currencyCode)))."
            }
            return nil
        case .percent:
            let total = enteredPercentsTotal()
            let delta = abs(total - Decimal(100))
            if delta > Decimal(0.1) {
                return "Percentages must add up to 100%."
            }
            return nil
        }
    }

    private func recomputeSplitValidity() {
        let valid = splitValidationError == nil
        if model.splitIsValid != valid { model.splitIsValid = valid }
    }

    // MARK: - Amount hero

    /// Maps the combined `[amount + currency symbol]` character count to a
    /// hero font size. Aggressive enough at the lower end (16pt) that even
    /// a 14-digit amount with a 3-char symbol fits the card.
    private static func heroFontSize(forDisplayLength length: Int) -> CGFloat {
        switch length {
        case ...5:  return 48
        case 6:     return 44
        case 7:     return 40
        case 8:     return 36
        case 9:     return 32
        case 10:    return 28
        case 11:    return 24
        case 12:    return 22
        case 13:    return 20
        case 14:    return 18
        default:    return 16
        }
    }

    private func recomputeHeroFontSize() {
        let symbolLength = SupportedCurrencies.symbol(for: model.currencyCode).count
        let size = Self.heroFontSize(forDisplayLength: displayedAmount.count + symbolLength)
        if size != heroFontSize { heroFontSize = size }
    }

    private var amountHeroContent: some View {
        VStack(spacing: 6) {
            Text("AMOUNT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.0)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Spacer(minLength: 0)
                TextField("0", text: Binding(
                    get: { displayedAmount },
                    set: { newValue in
                        let normalized = Self.normalizeAmount(newValue)
                        model.amountText = normalized
                        displayedAmount = Self.formatAmountForDisplay(normalized)
                    }
                ))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .focused($amountFocused)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 40)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("expenseAmountField")
                .onChange(of: amountFocused) { _, focused in
                    if focused && model.amountText == "0" {
                        model.amountText = ""
                        displayedAmount = ""
                    }
                    if !focused && model.amountText.trimmingCharacters(in: .whitespaces).isEmpty {
                        model.amountText = "0"
                        displayedAmount = "0"
                    }
                    recomputeHeroFontSize()
                }
                .onChange(of: model.amountText) { _, newValue in
                    if Self.normalizeAmount(displayedAmount) != newValue {
                        displayedAmount = Self.formatAmountForDisplay(newValue)
                    }
                }
                .onChange(of: displayedAmount) { _, _ in recomputeHeroFontSize() }
                .onChange(of: model.currencyCode) { _, _ in recomputeHeroFontSize() }
                .onAppear {
                    displayedAmount = Self.formatAmountForDisplay(model.amountText)
                    recomputeHeroFontSize()
                }

                Button {
                    showingCurrencyPicker = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(SupportedCurrencies.symbol(for: model.currencyCode))
                            .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.bold))
                    }
                    .foregroundStyle(model.accent.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("currencyPickerButton")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 4) {
                Text(model.currencyCode).monospaced()
                Text("·")
                Text(SupportedCurrencies.displayName(for: model.currencyCode))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Primary section (amount + description + category)

    private var primarySection: some View {
        VStack(spacing: 0) {
            amountHeroContent
                .padding(.vertical, 20)
                .background(
                    LinearGradient(
                        colors: [model.accent.opacity(0.26), model.accent.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .contentShape(Rectangle())
                .onTapGesture { amountFocused = true }

            detailsFields
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(model.accent.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: model.accent.opacity(0.14), radius: 16, x: 0, y: 6)
        .alert("New category", isPresented: $showingCustomCategoryAlert) {
            TextField("e.g. Groceries", text: $customCategoryName)
                .textInputAutocapitalization(.words)
            Button("Add") { commitCustomCategory() }
                .disabled(customCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type a short label. Categories you create here can be reused in this group's expenses.")
        }
    }

    // MARK: - Details (description + category) / Date cards

    private var detailsFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Description", text: $model.description)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("expenseDescriptionField")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
            )

            Menu {
                Picker("Category", selection: $model.category) {
                    ForEach(categoryPickerOptions, id: \.self) { c in
                        Label {
                            Text(c.displayName)
                        } icon: {
                            Image(c.lucideIconName)
                                .renderingMode(.template)
                        }
                        .tag(c)
                        .accessibilityIdentifier("categoryMenuItem_\(c.raw)")
                    }
                }
                Divider()
                Button {
                    customCategoryName = ""
                    showingCustomCategoryAlert = true
                } label: {
                    Label("Custom category…", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("categoryMenuItem_custom")
            } label: {
                HStack(spacing: 8) {
                    Image(model.category.lucideIconName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(model.accent)
                    Text(model.category.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.pageBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .tint(model.accent)
            .accessibilityIdentifier("categoryMenu")
        }
    }

    private func commitCustomCategory() {
        let trimmed = customCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.category = ExpenseCategory(trimmed)
        customCategoryName = ""
    }

    /// Date-only card, used when the group has no active members
    /// (the breakdown section can't render Paid by / Split between
    /// without members, but the user can still pick a date).
    private var dateOnlySection: some View {
        cardFrame(title: "Date") {
            dateTile
        }
        .modifier(DatePickerSheetModifier(
            isPresented: $showingDateSheet,
            date: $model.date,
            tint: model.accent
        ))
    }

    private func breakdownSection(members: [Member]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                breakdownSubheader(title: "Paid by")
                paidByContent(members: members)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 10) {
                breakdownSubheader(title: "Date")
                dateTile
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 10) {
                breakdownSubheader(
                    title: "Split between",
                    trailing: "\(model.participantIDs.count) of \(members.count)"
                )
                splitBetweenContent(members: members)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
        .modifier(DatePickerSheetModifier(
            isPresented: $showingDateSheet,
            date: $model.date,
            tint: model.accent
        ))
        .sheet(isPresented: $showingMultiPayerSheet) {
            MultiPayerSheet(
                members: members,
                total: model.amount,
                currencyCode: model.currencyCode,
                isYou: isYou,
                initialPayments: model.payments,
                initialPrimaryPayerID: model.payerID
            ) { payments, primary in
                model.payments = payments
                model.payerID = primary
            }
        }
    }

    @ViewBuilder
    private func breakdownSubheader(title: String, trailing: String? = nil) -> some View {
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
    }

    private var dateTile: some View {
        Button {
            showingDateSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(model.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(relativeDateLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCustomDate ? model.accent.opacity(0.12) : AppTheme.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isCustomDate ? model.accent.opacity(0.28) : AppTheme.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("expenseDateTile")
        .accessibilityLabel("Date: \(model.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))")
    }

    /// Human-friendly relative description of the selected date:
    /// "Today" / "Yesterday" / "3 days ago" / "in 2 days" / "Aug 15, 2025".
    private var relativeDateLabel: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let candidate = calendar.startOfDay(for: model.date)
        let days = calendar.dateComponents([.day], from: today, to: candidate).day ?? 0
        switch days {
        case 0:  return "Today"
        case -1: return "Yesterday"
        case 1:  return "Tomorrow"
        case let d where d < 0 && d >= -30:
            return "\(-d) days ago"
        case let d where d > 0 && d <= 30:
            return "in \(d) days"
        default:
            return model.date.formatted(.dateTime.year().month(.abbreviated).day())
        }
    }

    /// True when the current date is neither today nor yesterday — i.e. the
    /// compact DatePicker is the authoritative selector.
    private var isCustomDate: Bool {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        return !dateMatches(today) && !dateMatches(yesterday)
    }

    private func dateMatches(_ other: Date) -> Bool {
        Calendar.current.isDate(model.date, inSameDayAs: other)
    }

    // MARK: - Members

    private func paidByContent(members: [Member]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payments = model.payments, !payments.isEmpty {
                multiPayerChip(members: members, payments: payments)
            } else {
                singlePayerMenu(members: members)
            }
            Button {
                showingMultiPayerSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                    Text(model.payments?.isEmpty == false
                         ? "Edit payers"
                         : "Multiple payers?")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("multiPayerToggle")
        }
    }

    private func singlePayerMenu(members: [Member]) -> some View {
        Menu {
            ForEach(members) { m in
                Button {
                    model.payerID = m.id
                } label: {
                    Label(
                        isYou(m) ? "\(m.name) (You)" : m.name,
                        systemImage: model.payerID == m.id ? "checkmark" : "person.crop.circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let payer = members.first(where: { $0.id == model.payerID }) {
                    AvatarView(emoji: payer.emoji, size: 22)
                    Text(isYou(payer) ? "\(payer.name) (You)" : payer.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Choose")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .tint(model.accent)
        .accessibilityIdentifier("paidByMenu")
    }

    private func multiPayerChip(members: [Member], payments: [ExpensePayment]) -> some View {
        let nameByID: [UUID: Member] = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        // Primary is `model.payerID` (highest-paid, set by the sheet on save) —
        // *not* `payments.first`, which is just insertion order. Fall back to
        // the first payment if `payerID` somehow isn't in the payments list.
        let payerIDs = Set(payments.map(\.memberID))
        let primary: Member? = {
            if let pid = model.payerID, payerIDs.contains(pid), let m = nameByID[pid] {
                return m
            }
            return payments.compactMap { nameByID[$0.memberID] }.first
        }()
        let othersCount = max(0, payments.count - 1)
        return HStack(spacing: 8) {
            if let primary {
                AvatarView(emoji: primary.emoji, size: 22)
                Text(primary.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Image(systemName: "person.2.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if othersCount > 0 {
                Text("+ \(othersCount) other\(othersCount == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.accent.opacity(0.3), lineWidth: 1)
        )
    }

    private func splitBetweenContent(members: [Member]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PillSegmented(
                items: SplitMode.allCases.map { mode in
                    .init(label: mode.label, tag: mode)
                },
                selection: Binding(
                    get: { splitMode },
                    set: { new in
                        if new != splitMode { Haptics.selection() }
                        splitMode = new
                    }
                ),
                tint: model.accent,
                inline: true,
                compact: true
            )

            VStack(spacing: 6) {
                ForEach(members) { m in
                    SplitRow(
                        member: m,
                        isYou: isYou(m),
                        isIncluded: model.participantIDs.contains(m.id),
                        mode: splitMode,
                        equalShare: equalShareForMember(m, members: members),
                        amountBinding: bindingForAmount(m),
                        percentBinding: bindingForPercent(m),
                        currencyCode: model.currencyCode,
                        tint: model.accent,
                        onToggle: { include in
                            Haptics.selection()
                            if include { model.participantIDs.insert(m.id) }
                            else       { model.participantIDs.remove(m.id) }
                        }
                    )
                }
            }

            splitSummaryRow(members: members)
        }
    }

    // MARK: - Split helpers

    private var includedMembers: [Member] {
        (model.group?.members ?? []).filter { model.participantIDs.contains($0.id) }
    }

    private func equalShareForMember(_ member: Member, members: [Member]) -> Decimal {
        let n = includedMembers.count
        guard n > 0, model.participantIDs.contains(member.id) else { return 0 }
        return model.amount / Decimal(n)
    }

    private func bindingForAmount(_ member: Member) -> Binding<String> {
        Binding(
            get: {
                if let stored = memberAmounts[member.id], !stored.isEmpty {
                    return stored
                }
                let share = equalShareForMember(member, members: model.group?.members ?? [])
                return share > 0 ? plainAmountString(share) : ""
            },
            set: { newValue in
                memberAmounts[member.id] = newValue
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    manuallyEditedAmountIDs.remove(member.id)
                } else {
                    manuallyEditedAmountIDs.insert(member.id)
                }
                redistributeAmountSplit()
            }
        )
    }

    /// In `.amount` mode, distribute `model.amount` minus the sum of
    /// user-edited shares equally across the remaining included members.
    /// Leaves manually-edited fields untouched. The last untouched row
    /// absorbs any cent-rounding residual so the column always sums to the
    /// expense total.
    private func redistributeAmountSplit() {
        guard splitMode == .amount else { return }
        let included = includedMembers
        let editedMembers = included.filter { manuallyEditedAmountIDs.contains($0.id) }
        let untouched = included.filter { !manuallyEditedAmountIDs.contains($0.id) }
        guard !untouched.isEmpty else { return }
        let editedSum = editedMembers.reduce(Decimal(0)) { acc, m in
            acc + (Decimal(string: memberAmounts[m.id] ?? "") ?? 0)
        }
        let total = model.amount
        let remaining = max(Decimal(0), total - editedSum)
        let perPerson = (remaining / Decimal(untouched.count)).roundedTo2()
        var residual = remaining
        for (i, m) in untouched.enumerated() {
            if i == untouched.count - 1 {
                memberAmounts[m.id] = plainAmountString(residual.roundedTo2())
            } else {
                memberAmounts[m.id] = plainAmountString(perPerson)
                residual -= perPerson
            }
        }
    }

    /// Keep multi-payer payments in sync when the expense total changes.
    /// Without this, `model.payments` (set by the multi-payer sheet) would
    /// keep summing to the *old* total while `model.amount` moved on —
    /// BalanceCalculator silently rewrites the last payer's credit to
    /// absorb the difference, producing balances that don't match the
    /// values the user actually typed.
    ///
    /// Strategy: if the previous sum was > 0, rescale every payer's amount
    /// proportionally. If the previous sum was 0 (e.g. the sheet was opened
    /// before the user typed a total), redistribute the new total evenly
    /// across the existing checked payers. The last entry absorbs any
    /// rounding residual so the array sums to the new total exactly.
    /// Proportional rescale preserves who-paid-most ordering, so the
    /// stored `model.payerID` (the primary) stays valid without rework.
    private func rescalePaymentsForNewTotal() {
        guard var current = model.payments, !current.isEmpty else { return }
        let newTotal = model.amount
        let oldSum = current.reduce(Decimal(0)) { $0 + $1.amount }
        if abs(newTotal - oldSum) <= Decimal(0.01) { return }

        if oldSum > 0 {
            var working: [ExpensePayment] = current.map { p in
                ExpensePayment(memberID: p.memberID, amount: (p.amount * newTotal / oldSum).roundedTo2())
            }
            let workingSum = working.reduce(Decimal(0)) { $0 + $1.amount }
            let delta = newTotal - workingSum
            if delta != 0, let lastIdx = working.indices.last {
                let last = working[lastIdx]
                working[lastIdx] = ExpensePayment(memberID: last.memberID, amount: (last.amount + delta).roundedTo2())
            }
            current = working
        } else if newTotal > 0 {
            let perShare = (newTotal / Decimal(current.count)).roundedTo2()
            var residual = newTotal
            current = current.enumerated().map { i, p in
                let amount: Decimal
                if i == current.count - 1 {
                    amount = residual.roundedTo2()
                } else {
                    amount = perShare
                    residual -= perShare
                }
                return ExpensePayment(memberID: p.memberID, amount: amount)
            }
        } else {
            current = current.map { ExpensePayment(memberID: $0.memberID, amount: 0) }
        }

        model.payments = current
    }

    private func bindingForPercent(_ member: Member) -> Binding<String> {
        Binding(
            get: {
                if let stored = memberPercents[member.id], !stored.isEmpty {
                    return stored
                }
                let n = includedMembers.count
                guard n > 0, model.participantIDs.contains(member.id) else { return "" }
                let share = Decimal(100) / Decimal(n)
                return plainPercentString(share)
            },
            set: { newValue in
                memberPercents[member.id] = newValue
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    manuallyEditedPercentIDs.remove(member.id)
                } else {
                    manuallyEditedPercentIDs.insert(member.id)
                }
                redistributePercentSplit()
            }
        )
    }

    /// In `.percent` mode, distribute the remaining 100% minus the sum of
    /// user-edited percents equally across the remaining included members.
    /// Mirror of `redistributeAmountSplit()`. The last untouched row absorbs
    /// any rounding residual so the column always sums to 100%.
    private func redistributePercentSplit() {
        guard splitMode == .percent else { return }
        let included = includedMembers
        let editedMembers = included.filter { manuallyEditedPercentIDs.contains($0.id) }
        let untouched = included.filter { !manuallyEditedPercentIDs.contains($0.id) }
        guard !untouched.isEmpty else { return }
        let editedSum = editedMembers.reduce(Decimal(0)) { acc, m in
            acc + (Decimal(string: memberPercents[m.id] ?? "") ?? 0)
        }
        let remaining = max(Decimal(0), Decimal(100) - editedSum)
        let perPerson = (remaining / Decimal(untouched.count)).roundedTo2()
        var residual = remaining
        for (i, m) in untouched.enumerated() {
            if i == untouched.count - 1 {
                memberPercents[m.id] = plainPercentString(residual.roundedTo2())
            } else {
                memberPercents[m.id] = plainPercentString(perPerson)
                residual -= perPerson
            }
        }
    }

    private func effectiveAmount(for member: Member) -> Decimal {
        if let stored = memberAmounts[member.id], !stored.isEmpty,
           let value = Decimal(string: stored) {
            return value
        }
        return equalShareForMember(member, members: model.group?.members ?? [])
    }

    private func effectivePercent(for member: Member) -> Decimal {
        if let stored = memberPercents[member.id], !stored.isEmpty,
           let value = Decimal(string: stored) {
            return value
        }
        let n = includedMembers.count
        guard n > 0, model.participantIDs.contains(member.id) else { return 0 }
        return Decimal(100) / Decimal(n)
    }

    /// Produces the `[ExpenseShare]?` payload for save, based on the current
    /// split mode. `.equal` returns nil (legacy equal split via
    /// participantIDs). `.amount` emits the entered per-member amounts.
    /// `.percent` converts each entered percent to an amount in the expense's
    /// currency; the last share absorbs rounding residual so the sum equals
    /// the expense amount exactly.
    func currentShares() -> [ExpenseShare]? {
        switch splitMode {
        case .equal:
            return nil
        case .amount:
            return includedMembers.map { member in
                ExpenseShare(
                    memberID: member.id,
                    amount: effectiveAmount(for: member)
                )
            }
        case .percent:
            var rows = includedMembers.map { member -> ExpenseShare in
                let percent = effectivePercent(for: member)
                let share = (model.amount * percent / Decimal(100))
                return ExpenseShare(
                    memberID: member.id,
                    amount: share.roundedTo2()
                )
            }
            guard !rows.isEmpty else { return [] }
            // Adjust the last row to absorb rounding residual so sum == amount.
            let runningSum = rows.dropLast().reduce(Decimal(0)) { $0 + $1.amount }
            let lastAmount = (model.amount - runningSum).roundedTo2()
            let last = rows.removeLast()
            rows.append(ExpenseShare(memberID: last.memberID, amount: lastAmount))
            return rows
        }
    }

    private func enteredAmountsTotal() -> Decimal {
        includedMembers.reduce(Decimal(0)) { acc, m in acc + effectiveAmount(for: m) }
    }

    private func enteredPercentsTotal() -> Decimal {
        includedMembers.reduce(Decimal(0)) { acc, m in acc + effectivePercent(for: m) }
    }

    /// Maps the local enum `SplitMode` to the persisted string key on
    /// `Expense.splitKind`. Equal mode persists as `nil` (= legacy behavior).
    static func splitKindString(for mode: SplitMode) -> String? {
        switch mode {
        case .equal:   return nil
        case .amount:  return "amount"
        case .percent: return "percent"
        }
    }

    private func plainAmountString(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private func plainPercentString(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 1, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    @ViewBuilder
    private func splitSummaryRow(members: [Member]) -> some View {
        switch splitMode {
        case .equal:
            EmptyView()
        case .amount:
            let entered = enteredAmountsTotal()
            let isValid = model.amount > 0 && abs(model.amount - entered) <= Decimal(0.01)
            summaryPill(
                leadingLabel: "Entered",
                leading: entered.formatted(.currency(code: model.currencyCode)),
                trailing: model.amount.formatted(.currency(code: model.currencyCode)),
                isValid: isValid
            )
        case .percent:
            let total = enteredPercentsTotal()
            let isValid = abs(total - Decimal(100)) <= Decimal(0.1)
            summaryPill(
                leadingLabel: "Total",
                leading: "\(decimalPercentString(total))%",
                trailing: "100%",
                isValid: isValid
            )
        }
    }

    private func summaryPill(leadingLabel: String, leading: String, trailing: String, isValid: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(isValid ? Color.green : Color.orange)
            Text(leadingLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(leading)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isValid ? Color.primary : Color.orange)
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((isValid ? Color.green : Color.orange).opacity(0.10))
        )
        .padding(.top, 2)
    }

    private func decimalPercentString(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 1, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private var membersEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Add members to this group before adding an expense.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
        .accessibilityIdentifier("addMembersHint")
    }

    // MARK: - Receipts card wrapper

    private var receiptsCard: some View {
        cardFrame(
            title: "Receipts",
            trailing: model.pendingReceipts.isEmpty ? nil : "\(model.pendingReceipts.count)/\(Self.maxReceipts)"
        ) {
            receiptsSection
        }
    }

    // MARK: - Card frame helper

    @ViewBuilder
    private func cardFrame<Content: View>(
        title: String,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var receiptsSection: some View {
        localReceiptsSection
    }

    private var localReceiptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.pendingReceipts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(model.pendingReceipts) { pending in
                            receiptThumbnail(pending: pending)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            attachButton(
                label: receiptAttachLabel,
                isDisabled: remainingReceiptSlots == 0
            )
        }
        .animation(.easeInOut(duration: 0.2), value: model.pendingReceipts.count)
        .confirmationDialog(
            "Add a receipt",
            isPresented: $showingAddDialog,
            titleVisibility: .visible
        ) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") {
                    DispatchQueue.main.async { showingCamera = true }
                }
            }
            Button("Choose from Library") {
                DispatchQueue.main.async { showingPhotosPicker = true }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in addPickedImage(image) }
                .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $showingPhotosPicker,
            selection: $photoPickerItems,
            maxSelectionCount: max(1, remainingReceiptSlots),
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotoPickerItems(items) }
        }
        .sheet(item: $viewerPayload) { payload in
            FullScreenReceiptViewer(
                receipts: payload.receipts,
                initialIndex: payload.initialIndex,
                canDelete: { r in
                    guard let group = model.group else { return true }
                    return store.canDeleteReceipt(r, in: group)
                },
                onDelete: { r in
                    removePending(id: r.id)
                }
            )
        }
    }

    private func receiptThumbnail(pending: PendingReceipt) -> some View {
        let source: ReceiptThumbnailSource
        let existing: ReceiptAttachment?
        switch pending {
        case .existing(let r):
            let fileURL = ReceiptStore.default().url(for: r.id)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                source = .url(fileURL)
            } else {
                source = .remote(receiptID: r.id)
            }
            existing = r
        case .new(_, let data):
            source = .data(data)
            existing = nil
        }
        // Thumbnails are tap-to-preview only; the delete affordance lives
        // in the full-screen viewer's toolbar so a 64×64 tile isn't fighting
        // the image for visual real estate.
        return ReceiptThumbnail(source: source)
            .frame(width: 64, height: 64)
        .accessibilityIdentifier("receiptThumbnail_\(pending.id.uuidString)")
        .contentShape(Rectangle())
        .onTapGesture {
            if let existing { openViewer(for: existing) }
        }
    }

    private var receiptAttachLabel: String {
        if remainingReceiptSlots == 0 { return "Receipt limit reached" }
        return model.pendingReceipts.isEmpty ? "Attach a photo" : "Attach another"
    }

    @ViewBuilder
    private func attachButton(label: String, isDisabled: Bool) -> some View {
        Button {
            showingAddDialog = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(model.accent))
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("receiptAddButton")
    }

    private func openViewer(for attachment: ReceiptAttachment) {
        let existingAttachments = model.pendingReceipts.compactMap { p -> ReceiptAttachment? in
            if case .existing(let a) = p { return a }
            return nil
        }
        guard let idx = existingAttachments.firstIndex(where: { $0.id == attachment.id }) else { return }
        viewerPayload = ViewerPayload(receipts: existingAttachments, initialIndex: idx)
    }

    private func addPickedImage(_ image: UIImage) {
        guard remainingReceiptSlots > 0 else { return }
        guard let data = ReceiptImagePipeline.compress(image) else { return }
        model.pendingReceipts.append(.new(id: UUID(), data: data))
    }

    private func removePending(id: UUID) {
        model.pendingReceipts.removeAll { $0.id == id }
    }

    @MainActor
    private func loadPhotoPickerItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            if remainingReceiptSlots == 0 { break }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                addPickedImage(image)
            }
        }
        photoPickerItems = []
    }

    private struct ViewerPayload: Identifiable {
        let id = UUID()
        let receipts: [ReceiptAttachment]
        let initialIndex: Int
    }
}

/// Shared graphical date-picker sheet so the breakdown section and the
/// no-members fallback present the same picker without duplicating the
/// `.sheet(...)` markup.
private struct DatePickerSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var date: Date
    let tint: Color

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            NavigationStack {
                DatePicker(
                    "Date",
                    selection: $date,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(tint)
                .padding()
                Spacer()
            }
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                        .fontWeight(.semibold)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct SplitRow: View {
    let member: Member
    let isYou: Bool
    let isIncluded: Bool
    let mode: ExpenseFormContent.SplitMode
    let equalShare: Decimal
    let amountBinding: Binding<String>
    let percentBinding: Binding<String>
    let currencyCode: String
    let tint: Color
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onToggle(!isIncluded)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(isIncluded ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.35)), lineWidth: 1.5)
                        .background(
                            Circle().fill(isIncluded ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear))
                        )
                        .frame(width: 22, height: 22)
                    if isIncluded {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isIncluded ? "Remove \(member.name)" : "Include \(member.name)")

            AvatarView(emoji: member.emoji, size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isIncluded ? .primary : .secondary)
                    .lineLimit(1)
                if isYou {
                    Text("You")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            valueView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isIncluded ? tint.opacity(0.08) : AppTheme.pageBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isIncluded ? tint.opacity(0.18) : AppTheme.borderHairline, lineWidth: 1)
        )
        .opacity(isIncluded ? 1.0 : 0.6)
        .animation(.snappy, value: isIncluded)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .simultaneousGesture(
            TapGesture().onEnded {
                // The value-input field absorbs its own taps via
                // .allowsHitTesting on each TextField; this gesture fires
                // when the user taps the row's padding, avatar, or name,
                // OR anywhere on the row when the row is currently
                // excluded (so typing a value isn't possible yet).
                if !mode.allowsValueFocus || !isIncluded {
                    onToggle(!isIncluded)
                }
            }
        )
    }

    @ViewBuilder
    private var valueView: some View {
        switch mode {
        case .equal:
            if isIncluded {
                Text(equalShare.formatted(.currency(code: currencyCode)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        case .amount:
            if isIncluded {
                TextField("0", text: amountBinding)
                    .keyboardType(.decimalPad)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .allowsHitTesting(isIncluded)
            } else {
                Text("—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        case .percent:
            if isIncluded {
                HStack(spacing: 2) {
                    TextField("0", text: percentBinding)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .allowsHitTesting(isIncluded)
                    Text("%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension Decimal {
    func roundedTo2() -> Decimal {
        var v = self
        var result = Decimal()
        NSDecimalRound(&result, &v, 2, .bankers)
        return result
    }
}
