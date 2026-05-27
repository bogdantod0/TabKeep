import SwiftUI

/// User-selectable appearance preference. Persisted to `UserDefaults`
/// (not the JSON store) because it's a device setting, not group data.
enum AppearancePreference: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    /// Drives `.preferredColorScheme(...)` at the app root.
    /// `nil` means "follow the system."
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Display label for the Settings picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}
