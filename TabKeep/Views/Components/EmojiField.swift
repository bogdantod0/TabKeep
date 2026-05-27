import SwiftUI
import UIKit

/// A text field that forces the iOS emoji keyboard so the user can pick
/// any system emoji. Accepts a single emoji character cluster; replaces
/// the binding and resigns first responder immediately after selection.
struct EmojiField: UIViewRepresentable {
    @Binding var text: String
    var pointSize: CGFloat = 48

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = ForcedEmojiTextField()
        tf.delegate = context.coordinator
        tf.textAlignment = .center
        // Use the public AppleColorEmoji font explicitly. The system font picks
        // `.AppleColorEmojiUI` which is missing on some simulator runtimes and
        // falls back to LastResort (tofu glyphs).
        tf.font = UIFont(name: "AppleColorEmoji", size: pointSize) ?? .systemFont(ofSize: pointSize)
        tf.tintColor = .clear
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []
        tf.text = text
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiField
        init(_ parent: EmojiField) { self.parent = parent }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                parent.text = ""
                textField.text = ""
                return false
            }
            if let first = string.first {
                let s = String(first)
                parent.text = s
                textField.text = s
                textField.resignFirstResponder()
            }
            return false
        }
    }
}

private final class ForcedEmojiTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes where mode.primaryLanguage == "emoji" {
            return mode
        }
        return super.textInputMode
    }
}
