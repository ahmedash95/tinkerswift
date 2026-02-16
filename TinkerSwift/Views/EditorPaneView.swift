import SwiftUI

struct EditorPaneView: View {
    @Environment(TinkerSwiftState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        AppKitCodeEditor(
            text: $appState.code,
            fontSize: 14 * appState.scale,
            showLineNumbers: appState.showLineNumbers,
            wrapLines: appState.wrapLines,
            highlightSelectedLine: appState.highlightSelectedLine,
            syntaxHighlighting: appState.syntaxHighlighting,
            colorScheme: appState.editorColorScheme
        )
        .id(
            "editor-\(appState.showLineNumbers)-\(appState.wrapLines)-\(appState.highlightSelectedLine)-\(appState.syntaxHighlighting)-\(appState.editorColorScheme.rawValue)-\(appState.laravelProjectPath)"
        )
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
