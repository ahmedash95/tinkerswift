import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TinkerSwiftState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView(columnVisibility: $appState.columnVisibility) {
            ProjectSidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            ReplWorkspaceView()
        }
        .frame(minWidth: 1000, minHeight: 620)
        .fileImporter(
            isPresented: $appState.isPickingProjectFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            appState.addProject(url.path)
        }
        .focusedSceneValue(\.runCodeAction, appState.runCode)
    }
}

#Preview {
    ContentView()
        .environment(TinkerSwiftState())
}
