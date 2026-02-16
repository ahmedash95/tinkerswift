import SwiftUI

struct ReplWorkspaceView: View {
    @Environment(TinkerSwiftState.self) private var appState

    var body: some View {
        HSplitView {
            EditorPaneView()
                .frame(minWidth: 320, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)

            ResultPaneView()
                .frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: appState.runCode) {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(appState.isRunning)
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: appState.isRunning ? "hourglass" : "timer")
                            Text(appState.executionTimeText)
                                .font(.callout.monospacedDigit())
                        }
                        .frame(minWidth: 92, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Execution time")

                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "memorychip")
                            Text(appState.memoryUsageText)
                                .font(.callout.monospacedDigit())
                        }
                        .frame(minWidth: 110, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Peak memory usage")
                }
            }
        }
        .navigationTitle(appState.selectedProjectName)
        .navigationSubtitle(appState.laravelProjectPath.isEmpty ? "No project selected" : appState.laravelProjectPath)
    }
}
