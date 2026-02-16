import STPluginNeon
import STTextView
import SwiftUI

struct AppKitCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let showLineNumbers: Bool
    let wrapLines: Bool
    let highlightSelectedLine: Bool
    let syntaxHighlighting: Bool
    let colorScheme: EditorColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView

        textView.textDelegate = context.coordinator
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.highlightSelectedLine = highlightSelectedLine
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        textView.text = text

        textView.gutterView?.textColor = .secondaryLabelColor
        textView.gutterView?.drawSeparator = true

        context.coordinator.applyEditorFont(fontSize, to: textView, force: true)
        context.coordinator.installPlugins(on: textView, syntaxHighlighting: syntaxHighlighting, colorScheme: colorScheme)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else {
            return
        }

        if (textView.text ?? "") != text {
            context.coordinator.isSyncing = true
            textView.text = text
            context.coordinator.isSyncing = false
        }

        textView.highlightSelectedLine = highlightSelectedLine
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        context.coordinator.applyEditorFont(fontSize, to: textView)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.gutterView?.textColor = .secondaryLabelColor
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        @Binding var text: String
        var isSyncing = false
        private var lastAppliedFontSize: CGFloat = 0
        private var didInstallPlugin = false

        init(text: Binding<String>) {
            _text = text
        }

        func installPlugins(on textView: STTextView, syntaxHighlighting: Bool, colorScheme: EditorColorScheme) {
            guard syntaxHighlighting, !didInstallPlugin else { return }
            let colorOnlyTheme = makeColorOnlyTheme(colorScheme)
            textView.addPlugin(NeonPlugin(theme: colorOnlyTheme, language: .php))
            didInstallPlugin = true
        }

        private func makeColorOnlyTheme(_ scheme: EditorColorScheme) -> Theme {
            switch scheme {
            case .default:
                return Theme(colors: Theme.default.colors, fonts: Theme.Fonts(fonts: [:]))
            case .ocean:
                return Theme(colors: Theme.Colors(colors: [
                    "plain": NSColor(hex: "#DDEAF7"),
                    "boolean": NSColor(hex: "#78DCE8"),
                    "comment": NSColor(hex: "#6B8BAA"),
                    "constructor": NSColor(hex: "#A6E22E"),
                    "function.call": NSColor(hex: "#A6E22E"),
                    "include": NSColor(hex: "#F78C6C"),
                    "keyword": NSColor(hex: "#C792EA"),
                    "keyword.function": NSColor(hex: "#C792EA"),
                    "keyword.return": NSColor(hex: "#C792EA"),
                    "method": NSColor(hex: "#82AAFF"),
                    "number": NSColor(hex: "#F78C6C"),
                    "operator": NSColor(hex: "#89DDFF"),
                    "parameter": NSColor(hex: "#FFCB6B"),
                    "punctuation.special": NSColor(hex: "#89DDFF"),
                    "string": NSColor(hex: "#C3E88D"),
                    "text.literal": NSColor(hex: "#C3E88D"),
                    "text.title": NSColor(hex: "#82AAFF"),
                    "type": NSColor(hex: "#FFCB6B"),
                    "variable.builtin": NSColor(hex: "#FF5370"),
                    "variable": NSColor(hex: "#DDEAF7")
                ]), fonts: Theme.Fonts(fonts: [:]))
            case .solarized:
                return Theme(colors: Theme.Colors(colors: [
                    "plain": NSColor(hex: "#839496"),
                    "boolean": NSColor(hex: "#2AA198"),
                    "comment": NSColor(hex: "#586E75"),
                    "constructor": NSColor(hex: "#B58900"),
                    "function.call": NSColor(hex: "#268BD2"),
                    "include": NSColor(hex: "#CB4B16"),
                    "keyword": NSColor(hex: "#859900"),
                    "keyword.function": NSColor(hex: "#859900"),
                    "keyword.return": NSColor(hex: "#859900"),
                    "method": NSColor(hex: "#268BD2"),
                    "number": NSColor(hex: "#D33682"),
                    "operator": NSColor(hex: "#6C71C4"),
                    "parameter": NSColor(hex: "#B58900"),
                    "punctuation.special": NSColor(hex: "#6C71C4"),
                    "string": NSColor(hex: "#2AA198"),
                    "text.literal": NSColor(hex: "#2AA198"),
                    "text.title": NSColor(hex: "#268BD2"),
                    "type": NSColor(hex: "#B58900"),
                    "variable.builtin": NSColor(hex: "#CB4B16"),
                    "variable": NSColor(hex: "#839496")
                ]), fonts: Theme.Fonts(fonts: [:]))
            }
        }

        func applyEditorFont(_ size: CGFloat, to textView: STTextView, force: Bool = false) {
            guard force || abs(lastAppliedFontSize - size) > 0.001 else { return }
            lastAppliedFontSize = size

            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            textView.font = font

            let length = (textView.text ?? "").utf16.count
            if length > 0 {
                textView.addAttributes([.font: font], range: NSRange(location: 0, length: length))
            }

            textView.gutterView?.font = font
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isSyncing, let textView = notification.object as? STTextView else {
                return
            }

            text = textView.text ?? ""
        }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
