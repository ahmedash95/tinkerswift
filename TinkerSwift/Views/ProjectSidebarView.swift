import SwiftUI

struct ProjectSidebarView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        VStack(spacing: 0) {
            List(selection: $workspaceState.selectedProjectID) {
                Section("Projects") {
                    if workspaceState.projects.isEmpty {
                        Text("No projects added")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceState.projects) { project in
                            Label(project.name, systemImage: project.connection.kind == .docker ? "shippingbox.fill" : "folder")
                                .tag(project.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

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
