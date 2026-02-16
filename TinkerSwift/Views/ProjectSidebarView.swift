import SwiftUI

struct ProjectSidebarView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        VStack(spacing: 0) {
            List(selection: $workspaceState.laravelProjectPath) {
                Section("Projects") {
                    if workspaceState.projects.isEmpty {
                        Text("No projects added")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceState.projects) { project in
                            Label(project.name, systemImage: "folder")
                                .tag(project.path)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button(action: { workspaceState.isPickingProjectFolder = true }) {
                    Label("Add Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}
