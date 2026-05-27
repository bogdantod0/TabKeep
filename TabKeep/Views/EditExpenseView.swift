// SplitBill/Views/EditExpenseView.swift
import SwiftUI

struct EditExpenseView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID
    let expenseID: UUID

    @State private var model: ExpenseEditorModel?
    @State private var showingDeleteConfirm = false
    @State private var showingUnsavedAlert = false

    var body: some View {
        Group {
            if let model {
                if model.isReady {
                    ExpenseEditor(model: model, onFinish: { dismiss() })
                } else {
                    ContentUnavailableView(
                        "Expense not found",
                        systemImage: "questionmark.circle"
                    )
                }
            } else {
                AppTheme.sheetBackground.ignoresSafeArea()
            }
        }
        .navigationTitle(model?.isReadOnly == true ? "View Expense" : "Edit Expense")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if model?.isDirty == true {
                        showingUnsavedAlert = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body)
                }
                .accessibilityIdentifier("expenseBackButton")
            }
            if model?.isReadOnly != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("deleteExpenseMenuItem")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                    }
                    .accessibilityIdentifier("expenseMoreMenu")
                }
            }
        }
        .confirmationDialog(
            "Delete this expense?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let m = model
                Task { try? await m?.beginDelete() }
                dismiss()
            }
            .accessibilityIdentifier("confirmDeleteButton")
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unsaved changes", isPresented: $showingUnsavedAlert) {
            Button("Discard changes", role: .destructive) { dismiss() }
                .accessibilityIdentifier("discardChangesButton")
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("You have unsaved changes. Discard them and go back?")
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { model?.lastSaveError != nil },
                set: { if !$0 { model?.lastSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model?.lastSaveError = nil }
        } message: {
            Text(model?.lastSaveError ?? "")
        }
        .task {
            if model == nil {
                let m = ExpenseEditorModel(
                    mode: .edit(groupID: groupID, expenseID: expenseID),
                    store: store
                )
                m.prepareIfNeeded()
                model = m
            }
        }
        .onAppear {
            store.activeEditingEntity = (groupID: groupID, entityID: expenseID)
        }
        .onDisappear {
            if store.activeEditingEntity?.entityID == expenseID {
                store.activeEditingEntity = nil
            }
        }
    }
}
