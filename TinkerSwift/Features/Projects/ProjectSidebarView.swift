import SwiftUI

struct ProjectSidebarView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState
        let showsProjectManagementControls = workspaceState.hasCompletedInitialRenderActivation

        VStack(spacing: 0) {
            List(selection: $workspaceState.selectedProjectID) {
                Section("Projects") {
                    if workspaceState.projects.isEmpty {
                        Text("No projects added")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceState.projects) { project in
                            projectRow(for: project, showsProjectManagementControls: showsProjectManagementControls)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if showsProjectManagementControls {
                Divider()

                HStack {
                    Menu {
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

                        Button {
                            workspaceState.isShowingSSHProjectSheet = true
                        } label: {
                            Label("Add SSH Project", systemImage: "network")
                        }
                    } label: {
                        Label("Add Project", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func projectRow(for project: WorkspaceProject, showsProjectManagementControls: Bool) -> some View {
        let label = Label(project.name, systemImage: project.connection.kind.projectSymbolName)
            .tag(project.id)

        if showsProjectManagementControls {
            label.contextMenu {
                if workspaceState.canEditProject(project) {
                    Button("Edit Details") {
                        workspaceState.beginEditingProject(project)
                    }
                }
                if workspaceState.canRenameProject(project) {
                    Button("Rename") {
                        workspaceState.beginRenamingProject(project)
                    }
                }
                if workspaceState.canDeleteProject(project) {
                    Divider()
                    Button("Delete", role: .destructive) {
                        workspaceState.deleteProject(project)
                    }
                }
            }
        } else {
            label
        }
    }
}
