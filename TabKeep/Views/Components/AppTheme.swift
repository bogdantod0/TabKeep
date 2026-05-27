import SwiftUI

/// Central color tokens for the SplitBill UI palette.
///
/// Mode-aware tokens are backed by asset-catalog colorsets in
/// `Assets.xcassets` with Any + Dark appearances. iOS resolves the
/// correct variant from the environment `colorScheme` — call sites
/// do not branch on appearance.
enum AppTheme {
    /// Outer screen background.
    static let pageBackground = Color("PageBackground", bundle: .main)

    /// Standard card / list-row background.
    static let cardBackground = Color("CardBackground", bundle: .main)

    /// Heavy-emphasis card background (group / personal header).
    /// The card stays a dark navy in both light and dark mode, so views
    /// that render it should keep their existing
    /// `.environment(\.colorScheme, .dark)` override to ensure
    /// `.primary` / `.secondary` text resolves to light variants.
    static let emphasisCardBackground = Color("EmphasisCardBackground", bundle: .main)

    /// Full-screen modal / sheet background. Distinct from `cardBackground`
    /// only so future palette shifts can move them independently.
    static let sheetBackground = Color("SheetBackground", bundle: .main)

    /// Brand accent. Deep cyan (#196C8A — HSL 196°, 69%, 32%). 5.9:1 on
    /// white. Mode-stable. Used for CTAs, borders, gradients, selected
    /// chips, highlights, and soft tints (via `.opacity(...)`).
    static let accent = Color(
        red: 25.0 / 255.0,
        green: 108.0 / 255.0,
        blue: 138.0 / 255.0
    )

    // MARK: - Functional colors

    /// Positive / settled. Emerald-700 (#047857, 6.1:1 on white). Cool
    /// vibrant green that bridges to the cyan brand. Used for the settled
    /// pill, positive balance labels, and `expenseAdded` activity rows.
    static let success = Color(
        red: 4.0 / 255.0,
        green: 120.0 / 255.0,
        blue: 87.0 / 255.0
    )

    /// Caution / pending settlement. Amber-700 (#B45309, 5.0:1 on white).
    /// The only warm tone in the palette — by design, caution wants visual
    /// contrast against the cool cyan/emerald/rose family. Used for the
    /// "to settle" badge, archive swipe action, and edit / draft activity rows.
    static let warning = Color(
        red: 180.0 / 255.0,
        green: 83.0 / 255.0,
        blue: 9.0 / 255.0
    )

    /// Error / destructive. Rose-700 (#BE123C, 6.4:1 on white). Cooler than
    /// red-600, pairs naturally with the cyan brand. Used for negative
    /// balance labels and delete activity rows.
    static let danger = Color(
        red: 190.0 / 255.0,
        green: 18.0 / 255.0,
        blue: 60.0 / 255.0
    )

    // MARK: - Elevation

    /// Standard card drop-shadow color (mode-aware).
    static let cardShadowColor = Color("CardShadow", bundle: .main)
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowYOffset: CGFloat = 4

    // MARK: - Borders

    /// Subtle hairline border for cards and chips.
    static let borderHairline = Color("BorderHairline", bundle: .main)

    /// Slightly stronger hairline border for cards that need more definition.
    static let borderHairlineStrong = Color("BorderHairlineStrong", bundle: .main)
}
