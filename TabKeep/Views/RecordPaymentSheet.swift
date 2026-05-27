// SplitBill/Views/RecordPaymentSheet.swift
import SwiftUI

struct RecordPaymentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID
    let from: Member
    let to: Member
    let suggestedAmount: Decimal

    @State private var amountText: String
    @State private var displayedAmount: String = ""
    @State private var heroFontSize: CGFloat = 48
    @State private var date: Date = Date()
    @State private var note: String = ""
    @State private var selectedExpenseIDs: Set<UUID> = []
    @State private var showingDateSheet = false
    @State private var isSaving = false
    @FocusState private var amountFocused: Bool

    init(groupID: UUID, from: Member, to: Member, suggestedAmount: Decimal) {
        self.groupID = groupID
        self.from = from
        self.to = to
        self.suggestedAmount = suggestedAmount
        _amountText = State(initialValue: NSDecimalNumber(decimal: suggestedAmount).stringValue)
    }

    private var amount: Decimal { Decimal(string: amountText) ?? 0 }

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    private static func normalizeAmount(_ raw: String) -> String {
        let grouping = Locale.current.groupingSeparator ?? ","
        let decimal = Locale.current.decimalSeparator ?? "."
        var out = raw.replacingOccurrences(of: grouping, with: "")
        if decimal != "." {
            out = out.replacingOccurrences(of: decimal, with: ".")
        }
        return out
    }

    private static func formatAmountForDisplay(_ normalized: String) -> String {
        if normalized.isEmpty { return "" }
        let hasTrailingSeparator = normalized.hasSuffix(".")
        guard let decimal = Decimal(string: normalized) else { return normalized }
        let formatted = amountFormatter.string(from: NSDecimalNumber(decimal: decimal)) ?? normalized
        return hasTrailingSeparator && !formatted.contains(Locale.current.decimalSeparator ?? ".")
            ? formatted + (Locale.current.decimalSeparator ?? ".")
            : formatted
    }

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
        let symbolLength = SupportedCurrencies.symbol(for: currencyCode).count
        let size = Self.heroFontSize(forDisplayLength: displayedAmount.count + symbolLength)
        if size != heroFontSize { heroFontSize = size }
    }
    private var canSave: Bool { amount > 0 && !isSaving }
    private var accent: Color { AppTheme.accent }
    private var currencyCode: String {
        store.group(id: groupID)?.currencyCode ?? "USD"
    }

    private var linkableExpenses: [Expense] {
        (store.group(id: groupID)?.expenses ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerStrip
                    amountHero
                    dateTile
                    noteField
                    ExpenseLinkPicker(
                        expenses: linkableExpenses,
                        currencyCode: currencyCode,
                        selectedIDs: $selectedExpenseIDs
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(AppTheme.sheetBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                stickyCTA
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        amountFocused = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(32)
        .sheet(isPresented: $showingDateSheet) {
            datePickerSheet
        }
    }

    private var stickyCTA: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Mark paid")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(canSave ? AppTheme.accent : AppTheme.accent.opacity(0.35))
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("recordPaymentButton")
            .animation(.snappy, value: canSave)
        }
        .background(AppTheme.sheetBackground)
    }

    private var headerStrip: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                AvatarView(emoji: from.emoji, size: 44)
                Text(from.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Image(systemName: "arrow.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.accent)
            VStack(spacing: 6) {
                AvatarView(emoji: to.emoji, size: 44)
                Text(to.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var amountHero: some View {
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
                        amountText = normalized
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
                .accessibilityIdentifier("paymentAmountField")
                .onChange(of: amountFocused) { _, focused in
                    if focused && amountText == "0" {
                        amountText = ""
                        displayedAmount = ""
                    }
                    if !focused && amountText.trimmingCharacters(in: .whitespaces).isEmpty {
                        amountText = "0"
                        displayedAmount = "0"
                    }
                    recomputeHeroFontSize()
                }
                .onChange(of: amountText) { _, newValue in
                    if Self.normalizeAmount(displayedAmount) != newValue {
                        displayedAmount = Self.formatAmountForDisplay(newValue)
                    }
                }
                .onChange(of: displayedAmount) { _, _ in recomputeHeroFontSize() }
                .onAppear {
                    displayedAmount = Self.formatAmountForDisplay(amountText)
                    recomputeHeroFontSize()
                }

                Text(SupportedCurrencies.symbol(for: currencyCode))
                    .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(accent.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            Text(currencyCode)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .monospaced()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.26), accent.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(accent.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.14), radius: 16, x: 0, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { amountFocused = true }
    }

    private var dateTile: some View {
        Button {
            showingDateSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to change")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paymentDateTile")
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(AppTheme.accent)
                .padding()
            Spacer()
        }
        .navigationTitle("Pick a date")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingDateSheet = false }
                    .fontWeight(.semibold)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            TextField("Optional note", text: $note)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
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
                .accessibilityIdentifier("paymentNoteField")
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await store.recordPayment(
                inGroup: groupID,
                fromMemberID: from.id,
                toMemberID: to.id,
                amount: amount,
                date: date,
                note: note,
                expenseIDs: selectedExpenseIDs.isEmpty ? nil : Array(selectedExpenseIDs)
            )
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
        }
    }
}
