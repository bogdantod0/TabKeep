import Foundation

/// The device owner's identity. Not a `Member` of any specific group — it's
/// the per-device profile that the app matches against members by name to
/// surface "my expenses" / "my share" inside each group.
struct User: Hashable, Codable {
    var name: String
    /// Single-character emoji shown as the user's profile glyph. Mirrors the
    /// emoji-picker pattern used for groups so onboarding/settings/profile
    /// look consistent with the rest of the app.
    var emoji: String
    /// Server-assigned user UUID once the device is signed in. Used to
    /// identify the user's own membership inside a group by id (not by
    /// name) so renames don't break the link. nil while anonymous.
    var serverID: UUID? = nil

    static let defaultEmoji = "🙂"
    static let empty = User(name: "", emoji: User.defaultEmoji, serverID: nil)

    /// True when the user has entered a non-blank name.
    var hasName: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Normalized name used for matching against group members
    /// (case-insensitive, whitespace-trimmed).
    var matchKey: String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
