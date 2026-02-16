import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsTab()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }
        }
        .padding(20)
        .frame(width: 460, height: 300)
    }
}

private struct EditorSettingsTab: View {
    @AppStorage("editor.showLineNumbers") private var showLineNumbers = true
    @AppStorage("editor.wrapLines") private var wrapLines = true
    @AppStorage("editor.highlightSelectedLine") private var highlightSelectedLine = true
    @AppStorage("editor.syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("editor.colorScheme") private var editorColorSchemeRaw = EditorColorScheme.default.rawValue

    private var colorSchemeBinding: Binding<EditorColorScheme> {
        Binding(
            get: { EditorColorScheme(rawValue: editorColorSchemeRaw) ?? .default },
            set: { editorColorSchemeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Editor Settings")
                .font(.title3.weight(.semibold))

            Toggle("Show Line Numbers", isOn: $showLineNumbers)
            Toggle("Wrap Lines", isOn: $wrapLines)
            Toggle("Highlight Current Line", isOn: $highlightSelectedLine)
            Toggle("Syntax Highlighting", isOn: $syntaxHighlighting)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color Scheme")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Color Scheme", selection: colorSchemeBinding) {
                    ForEach(EditorColorScheme.allCases) { scheme in
                        Text(scheme.title).tag(scheme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }
}
