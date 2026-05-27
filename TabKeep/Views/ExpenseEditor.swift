import SwiftUI

struct ExpenseEditor: View {
    @Bindable var model: ExpenseEditorModel
    var onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if model.isRestoringDraft {
                    restoringHeader
                }
                if model.isReadOnly {
                    readOnlyHeader
                }
                ExpenseFormContent(model: model)
                    .disabled(model.isReadOnly)
            }
            .padding(.vertical, 8)
            .padding(.bottom, 24)
        }
        .background(AppTheme.sheetBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if !model.isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    saveToolbarButton
                }
            }
        }
        .onAppear { model.prepareIfNeeded() }
    }

    private var readOnlyHeader: some View {
        let (icon, title, detail): (String, String, String) = {
            switch model.readOnlyReason {
            case .archived:
                return ("archivebox.fill",
                        "Read-only — group is archived",
                        "Unarchive the group to make changes.")
            case .noPermission:
                return ("eye.fill",
                        "View only",
                        "Only the group host or someone listed in this expense can edit it.")
            case .none:
                // Unreachable — this view is only rendered when isReadOnly.
                return ("eye.fill", "View only", "")
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
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
        .padding(.horizontal)
    }

    private var saveToolbarButton: some View {
        Button {
            Task {
                do {
                    try await model.save()
                    onFinish()
                } catch {
                    // Haptics already fired inside model.save()
                }
            }
        } label: {
            if model.isSaving {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text(saveLabel)
            }
        }
        .fontWeight(.semibold)
        .disabled(!model.canSave || model.isSaving)
        .accessibilityIdentifier("saveExpenseButton")
        .animation(.snappy, value: model.canSave)
    }

    private var saveLabel: String {
        model.isEditing ? "Save" : "Add"
    }
}
