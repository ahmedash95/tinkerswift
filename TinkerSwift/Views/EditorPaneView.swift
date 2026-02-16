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
            syntaxHighlighting: appState.syntaxHighlighting
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
