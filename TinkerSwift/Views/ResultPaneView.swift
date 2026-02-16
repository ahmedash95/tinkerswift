import SwiftUI

struct ResultPaneView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    private var formattedResult: AttributedString {
        ResultFormatter.format(workspaceState.result, fontSize: 14 * workspaceState.scale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical) {
                Text(formattedResult)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if workspaceState.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum ResultFormatter {
    static func format(_ raw: String, fontSize: CGFloat) -> AttributedString {
        let text = raw.isEmpty ? "(empty)" : raw
        if let json = prettyPrintedJSON(from: text) {
            return highlightJSON(json, fontSize: fontSize)
        }
        return plain(text, fontSize: fontSize)
    }

    private static func prettyPrintedJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return pretty
    }

    private static func plain(_ text: String, fontSize: CGFloat) -> AttributedString {
        let attr = NSMutableAttributedString(string: text)
        attr.addAttributes(baseAttributes(fontSize: fontSize), range: NSRange(location: 0, length: attr.length))
        return AttributedString(attr)
    }

    private static func highlightJSON(_ json: String, fontSize: CGFloat) -> AttributedString {
        let attr = NSMutableAttributedString(string: json)
        let fullRange = NSRange(location: 0, length: attr.length)
        attr.addAttributes(baseAttributes(fontSize: fontSize), range: fullRange)

        apply(pattern: #"\"(?:\\.|[^\"\\])*\""#, color: .systemGreen, to: attr)
        apply(pattern: #"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, to: attr)
        apply(pattern: #"\b(?:true|false|null)\b"#, color: .systemPurple, to: attr)
        apply(pattern: #"[{}\[\]:,]"#, color: .secondaryLabelColor, to: attr)
        apply(pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: .systemBlue, to: attr)

        return AttributedString(attr)
    }

    private static func apply(pattern: String, color: NSColor, to attr: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(location: 0, length: attr.length)
        regex.matches(in: attr.string, options: [], range: range).forEach { match in
            attr.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }
}
