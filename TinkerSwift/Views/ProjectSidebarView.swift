import SwiftUI

struct ProjectSidebarView: View {
    @Environment(TinkerSwiftState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            List(selection: $appState.laravelProjectPath) {
                Section("Projects") {
                    if appState.projects.isEmpty {
                        Text("No projects added")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.projects) { project in
                            Label(project.name, systemImage: "folder")
                                .tag(project.path)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button(action: { appState.isPickingProjectFolder = true }) {
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
