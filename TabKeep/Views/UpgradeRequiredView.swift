import SwiftUI

struct UpgradeRequiredView: View {
    let minimum: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Update TabKeep")
                .font(.title.bold())
            Text("This version of TabKeep is no longer supported. Please update from the App Store to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Text("Minimum required: \(minimum)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .interactiveDismissDisabled(true)
    }
}
