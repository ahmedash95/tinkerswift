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
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 16) {
            Text("Editor Settings")
                .font(.title3.weight(.semibold))

            Toggle("Show Line Numbers", isOn: $appModel.showLineNumbers)
            Toggle("Wrap Lines", isOn: $appModel.wrapLines)
            Toggle("Highlight Current Line", isOn: $appModel.highlightSelectedLine)
            Toggle("Syntax Highlighting", isOn: $appModel.syntaxHighlighting)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }
}
