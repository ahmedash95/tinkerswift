import SwiftUI

struct ReplWorkspaceView: View {
    @Environment(WorkspaceState.self) private var workspaceState

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
                Menu {
                    if workspaceState.projects.isEmpty {
                        Text("No projects added")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceState.projects) { project in
                            Button {
                                workspaceState.laravelProjectPath = project.path
                            } label: {
                                Label(project.name, systemImage: workspaceState.laravelProjectPath == project.path ? "checkmark" : "folder")
                            }
                        }
                    }

                    Divider()

                    Button {
                        workspaceState.isPickingProjectFolder = true
                    } label: {
                        Label("Add Project", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .help("Switch Project")

                Button(action: workspaceState.toggleRunStop) {
                    Label(workspaceState.isRunning ? "Stop" : "Run", systemImage: workspaceState.isRunning ? "stop.fill" : "play.fill")
                }
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 18) {
                    HStack(spacing: 6) {
                        Image(systemName: workspaceState.isRunning ? "hourglass" : "timer")
                        Text(workspaceState.executionTimeText)
                    }
                    .help("Execution time")

                    HStack(spacing: 6) {
                        Image(systemName: "memorychip")
                        Text(workspaceState.memoryUsageText)
                    }
                    .help("Peak memory usage")
                }
            }
        }
        .navigationTitle(workspaceState.selectedProjectName)
        .navigationSubtitle(workspaceState.laravelProjectPath.isEmpty ? "No project selected" : workspaceState.laravelProjectPath)
    }
}
