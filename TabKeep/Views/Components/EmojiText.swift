import SwiftUI

/// Renders an emoji glyph at a given size. Isolated so we can swap the
/// implementation if a specific simulator runtime or platform misbehaves.
struct EmojiText: View {
    let emoji: String
    let size: CGFloat

    var body: some View {
        Text(emoji)
            .font(.system(size: size))
            .accessibilityLabel(emoji)
    }
}
