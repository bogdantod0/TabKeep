import UIKit

/// Thin wrapper around UIKit feedback generators, used to add tactile
/// reinforcement on key interactions inside the expense modal. When
/// Reduce Motion is enabled we short-circuit — financial apps should
/// be quiet under that preference, not chatty.
enum Haptics {
    static func selection() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
