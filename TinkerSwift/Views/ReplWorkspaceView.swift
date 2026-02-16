import SwiftUI

struct ReplWorkspaceView: View {
    @Environment(TinkerSwiftState.self) private var appState

    var body: some View {
        HSplitView {
            EditorPaneView()
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            ResultPaneView()
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: appState.toggleRunStop) {
                    Label(appState.isRunning ? "Stop" : "Run", systemImage: appState.isRunning ? "stop.fill" : "play.fill")
                }
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 18) {
                    HStack(spacing: 6) {
                        Image(systemName: appState.isRunning ? "hourglass" : "timer")
                        Text(appState.executionTimeText)
                    }
                    .help("Execution time")

                    HStack(spacing: 6) {
                        Image(systemName: "memorychip")
                        Text(appState.memoryUsageText)
                    }
                    .help("Peak memory usage")
                }
            }
        }
        .navigationTitle(appState.selectedProjectName)
        .navigationSubtitle(appState.laravelProjectPath.isEmpty ? "No project selected" : appState.laravelProjectPath)
    }
}
