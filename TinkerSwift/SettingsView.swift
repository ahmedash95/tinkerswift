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
    @Environment(TinkerSwiftState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 16) {
            Text("Editor Settings")
                .font(.title3.weight(.semibold))

            Toggle("Show Line Numbers", isOn: $appState.showLineNumbers)
            Toggle("Wrap Lines", isOn: $appState.wrapLines)
            Toggle("Highlight Current Line", isOn: $appState.highlightSelectedLine)
            Toggle("Syntax Highlighting", isOn: $appState.syntaxHighlighting)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color Scheme")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Color Scheme", selection: $appState.editorColorScheme) {
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
