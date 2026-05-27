import SwiftUI

/// Compact "↑12%" / "↓4%" pill used on Stats cards (category rows, KPI tiles).
/// Pass `delta = nil` to render an empty view (no chip when previous data is
/// missing or the comparison is undefined).
struct DeltaChip: View {
    let delta: Int?
    var size: Size = .compact

    enum Size {
        case compact   // "↑12%"
        case withSuffix(String)   // "↑12% vs Apr"
    }

    var body: some View {
        if let delta, delta != 0 {
            chip(for: delta)
        }
    }

    private func chip(for delta: Int) -> some View {
        let isUp = delta > 0
        let color = isUp ? AppTheme.success : AppTheme.danger
        let symbol = isUp ? "arrow.up" : "arrow.down"
        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            Text(displayText(delta: delta))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
        .fixedSize()
        .accessibilityLabel(accessibilityLabel(delta: delta))
    }

    private func displayText(delta: Int) -> String {
        let core = "\(abs(delta))%"
        switch size {
        case .compact:
            return core
        case .withSuffix(let suffix):
            return "\(core) \(suffix)"
        }
    }

    private func accessibilityLabel(delta: Int) -> String {
        let direction = delta >= 0 ? "up" : "down"
        switch size {
        case .compact:
            return "\(direction) \(abs(delta)) percent"
        case .withSuffix(let suffix):
            return "\(direction) \(abs(delta)) percent \(suffix)"
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        DeltaChip(delta: 12)
        DeltaChip(delta: -4)
        DeltaChip(delta: 0)
        DeltaChip(delta: nil)
        DeltaChip(delta: 18, size: .withSuffix("vs Apr"))
    }
    .padding()
    .background(AppTheme.pageBackground)
}
