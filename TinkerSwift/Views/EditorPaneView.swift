import SwiftUI

struct EditorPaneView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        AppKitCodeEditor(
            text: $workspaceState.code,
            fontSize: 14 * workspaceState.scale,
            showLineNumbers: workspaceState.showLineNumbers,
            wrapLines: workspaceState.wrapLines,
            highlightSelectedLine: workspaceState.highlightSelectedLine,
            syntaxHighlighting: workspaceState.syntaxHighlighting,
            projectPath: workspaceState.completionProjectPath,
            lspCompletionEnabled: workspaceState.effectiveLSPCompletionEnabled,
            lspAutoTriggerEnabled: workspaceState.lspAutoTriggerEnabled,
            lspServerPathOverride: workspaceState.lspServerPathOverride
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
