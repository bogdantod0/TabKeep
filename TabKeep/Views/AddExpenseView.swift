// SplitBill/Views/AddExpenseView.swift
import SwiftUI

struct AddExpenseView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID

    @State private var model: ExpenseEditorModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ExpenseEditor(model: model, onFinish: { dismiss() })
                }
            }
            .navigationTitle("New Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(32)
        .task {
            if model == nil {
                let m = ExpenseEditorModel(
                    mode: .create(groupID: groupID),
                    store: store
                )
                m.prepareIfNeeded()
                model = m
            }
        }
    }
}
