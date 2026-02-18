import SwiftUI
import UniformTypeIdentifiers

struct ReplWorkspaceView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

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
                                workspaceState.selectedProjectID = project.id
                            } label: {
                                Label(project.name, systemImage: workspaceState.selectedProjectID == project.id ? "checkmark" : (project.connection.kind == .docker ? "shippingbox.fill" : "folder"))
                            }
                        }
                    }

                    Divider()

                    Button {
                        workspaceState.isPickingProjectFolder = true
                    } label: {
                        Label("Add Local Project", systemImage: "folder.badge.plus")
                    }

                    Button {
                        workspaceState.isShowingDockerProjectSheet = true
                    } label: {
                        Label("Add Docker Project", systemImage: "shippingbox")
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
        .navigationSubtitle(workspaceState.selectedProjectSubtitle)
        .fileImporter(
            isPresented: $workspaceState.isPickingProjectFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            workspaceState.addLocalProject(url.path)
        }
        .sheet(isPresented: $workspaceState.isShowingDockerProjectSheet) {
            DockerProjectSetupSheet()
                .environment(workspaceState)
        }
    }
}
