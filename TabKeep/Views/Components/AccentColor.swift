import SwiftUI

enum GroupAccent {
    /// Brand accent. Backed by `AppTheme.accent` so the palette has a single
    /// source of truth.
    static var brand: Color { AppTheme.accent }
}

#Preview {
    HStack {
        Circle().fill(GroupAccent.brand).frame(width: 32, height: 32)
        Text("Brand accent")
    }
    .padding()
}
