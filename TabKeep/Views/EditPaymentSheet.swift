// SplitBill/Views/EditPaymentSheet.swift
import SwiftUI

struct EditPaymentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID
    let paymentID: UUID

    @State private var amountText: String = "0"
    @State private var fromMemberID: UUID?
    @State private var toMemberID: UUID?
    @State private var date: Date = Date()
    @State private var note: String = ""
    @State private var showingDateSheet = false
    @State private var showingDeleteConfirm = false
    @State private var showingUnsavedAlert = false
    @State private var isSaving = false
    @State private var didPrefill = false
    @State private var initialSnapshot: Snapshot?
    @State private var isRestoringDraft: Bool = false
    @State private var selectedExpenseIDs: Set<UUID> = []
    @FocusState private var amountFocused: Bool

    private struct Snapshot: Equatable {
        let amountText: String
        let fromMemberID: UUID?
        let toMemberID: UUID?
        let date: Date
        let note: String
        let selectedExpenseIDs: Set<UUID>
    }

    private var group: ExpenseGroup? { store.group(id: groupID) }
    private var payment: Payment? {
        (group?.payments ?? []).first { $0.id == paymentID }
    }
    /// Full member list (including archived) — used for name resolution
    /// when rendering the currently-selected from/to label, so a payment
    /// against an archived member still shows their name.
    private var members: [Member] { group?.members ?? [] }
    /// Pickable members only — drives the picker menu so archived and
    /// ghost (account-deleted, userID == nil) members can no longer be
    /// chosen as from/to. They still resolve names for historical rows
    /// via the unfiltered `members`.
    private var activeMembers: [Member] { members.pickable(currentUserServerID: store.user.serverID) }
    private var accent: Color { AppTheme.accent }
    private var currencyCode: String { group?.currencyCode ?? "USD" }
    private var amount: Decimal { Decimal(string: amountText) ?? 0 }
    private var linkableExpenses: [Expense] {
        (group?.expenses ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.date > $1.date }
    }

    private var fromMember: Member? {
        members.first { $0.id == fromMemberID }
    }
    private var toMember: Member? {
        members.first { $0.id == toMemberID }
    }

    private var canSave: Bool {
        amount > 0
        && fromMemberID != nil && toMemberID != nil
        && fromMemberID != toMemberID
        && !isSaving
    }

    private var currentSnapshot: Snapshot {
        Snapshot(
            amountText: amountText,
            fromMemberID: fromMemberID,
            toMemberID: toMemberID,
            date: date,
            note: note,
            selectedExpenseIDs: selectedExpenseIDs
        )
    }

    private var isDirty: Bool {
        guard let initialSnapshot else { return false }
        return initialSnapshot != currentSnapshot
    }

    var body: some View {
        NavigationStack {
            Group {
                if payment != nil {
                    formScroll
                } else {
                    ContentUnavailableView("Payment not found", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle("Edit payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { showingUnsavedAlert = true }
                        else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("deletePaymentMenuItem")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("paymentMoreMenu")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { amountFocused = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(32)
        .sheet(isPresented: $showingDateSheet) {
            datePickerSheet
        }
        .confirmationDialog("Delete this payment?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let pid = paymentID
                let gid = groupID
                Task { try? await store.beginDeletePayment(id: pid, inGroup: gid) }
                dismiss()
            }
            .accessibilityIdentifier("confirmDeletePaymentButton")
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unsaved changes", isPresented: $showingUnsavedAlert) {
            Button("Discard changes", role: .destructive) { dismiss() }
                .accessibilityIdentifier("discardPaymentChangesButton")
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("You have unsaved changes. Discard them and go back?")
        }
        .onAppear(perform: prefillIfNeeded)
    }

    private var formScroll: some View {
        ScrollView {
            VStack(spacing: 18) {
                if isRestoringDraft { restoringHeader }
                memberPicker(label: "From", selection: $fromMemberID, exclude: toMemberID)
                memberPicker(label: "To", selection: $toMemberID, exclude: fromMemberID)
                amountHero
                dateTile
                noteField
                ExpenseLinkPicker(
                    expenses: linkableExpenses,
                    currencyCode: currencyCode,
                    selectedIDs: $selectedExpenseIDs
                )
                cta
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    private func prefillIfNeeded() {
        guard !didPrefill, let p = payment else { return }
        amountText = NSDecimalNumber(decimal: p.amount).stringValue
        fromMemberID = p.fromMemberID
        toMemberID = p.toMemberID
        date = p.date
        note = p.note ?? ""
        selectedExpenseIDs = Set(p.expenseIDs ?? [])

        // Overlay rejected draft if one exists.
        let key = EntityKey.payment(paymentID, in: groupID)
        if let draft = store.drafts[key],
           case .upsert(let payload) = draft.kind {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let drafted = try? dec.decode(Payment.self, from: payload) {
                amountText = NSDecimalNumber(decimal: drafted.amount).stringValue
                fromMemberID = drafted.fromMemberID
                toMemberID = drafted.toMemberID
                date = drafted.date
                note = drafted.note ?? ""
                selectedExpenseIDs = Set(drafted.expenseIDs ?? [])
                isRestoringDraft = true
            }
        }

        initialSnapshot = currentSnapshot
        didPrefill = true
    }

    private func memberPicker(label: String, selection: Binding<UUID?>, exclude: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Menu {
                ForEach(activeMembers) { m in
                    Button {
                        selection.wrappedValue = m.id
                    } label: {
                        HStack {
                            Text(m.name)
                            if selection.wrappedValue == m.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(m.id == exclude)
                }
            } label: {
                HStack(spacing: 10) {
                    if let m = members.first(where: { $0.id == selection.wrappedValue }) {
                        AvatarView(emoji: m.emoji, size: 28)
                        Text(m.name)
                            .font(.subheadline.weight(.medium))
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
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.cardBackground)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var amountHero: some View {
        VStack(spacing: 6) {
            Text("AMOUNT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.0)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Spacer(minLength: 0)
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .focused($amountFocused)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 40)
                    .accessibilityIdentifier("paymentAmountField")
                Text(SupportedCurrencies.symbol(for: currencyCode))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.cardBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.cardBackground)
                )
                .accessibilityIdentifier("paymentNoteField")
        }
    }

    private var cta: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 10) {
                if isSaving {
                    ProgressView().tint(.white).scaleEffect(0.9)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                }
                Text(isSaving ? "Saving…" : "Save changes")
                    .font(.body.weight(.semibold))
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(canSave ? AppTheme.accent : Color.secondary.opacity(0.25)))
            .foregroundStyle(.white)
            .shadow(color: canSave ? accent.opacity(0.30) : .clear, radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .accessibilityIdentifier("savePaymentButton")
        .animation(.snappy, value: canSave)
    }

    @MainActor
    private func save() async {
        guard let fromMemberID, let toMemberID else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.editPayment(
                id: paymentID,
                inGroup: groupID,
                fromMemberID: fromMemberID,
                toMemberID: toMemberID,
                amount: amount,
                date: date,
                note: note,
                expenseIDs: selectedExpenseIDs.isEmpty ? nil : Array(selectedExpenseIDs)
            )
            if isRestoringDraft {
                store.discardDraft(.payment(paymentID, in: groupID))
                isRestoringDraft = false
            }
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
        }
    }

    private var restoringHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reapplying your saved edit")
                    .font(.subheadline.weight(.semibold))
                Text("These fields are from your offline edit. Save to push them, or back out to keep the server's version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}
