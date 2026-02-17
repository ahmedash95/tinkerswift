import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        NavigationSplitView(columnVisibility: $workspaceState.columnVisibility) {
            ProjectSidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } content: {
            EditorPaneView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 700)
        } detail: {
            ResultPaneView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 520)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 620)
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

            ToolbarItemGroup(placement: .principal) {
                Button(action: {}) {
                    Label(workspaceState.memoryUsageText, systemImage: "memorychip")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("Peak memory usage")

                Button(action: {}) {
                    Label(workspaceState.executionTimeText, systemImage: workspaceState.isRunning ? "hourglass" : "stopwatch")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("Execution time")
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    workspaceState.resultViewMode = .pretty
                } label: {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(workspaceState.resultViewMode == .pretty ? .primary : .secondary)
                }
                .help("Pretty View")

                Button {
                    workspaceState.resultViewMode = .raw
                } label: {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(workspaceState.resultViewMode == .raw ? .primary : .secondary)
                }
                .help("Raw View")

                Menu {
                    if workspaceState.resultPresentation.hasStdout {
                        streamMenuButton("Output", mode: .output)
                    }
                    if workspaceState.resultPresentation.hasStderr {
                        streamMenuButton("Error", mode: .error)
                    }
                    if workspaceState.resultPresentation.hasStdout && workspaceState.resultPresentation.hasStderr {
                        streamMenuButton("Both", mode: .combined)
                    }
                    if !workspaceState.resultPresentation.hasStdout && !workspaceState.resultPresentation.hasStderr {
                        Text("No streams available")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(workspaceState.canChooseResultStream ? .primary : .secondary)
                }
                .help("Choose Stream")
                .disabled(!workspaceState.canChooseResultStream)

                Button(action: workspaceState.copyVisibleResultToPasteboard) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Visible Output")
                .disabled(!workspaceState.canCopyResultOutput)
            }
        }
        .navigationTitle(workspaceState.selectedProjectName)
        .navigationSubtitle(workspaceState.laravelProjectPath.isEmpty ? "No project selected" : workspaceState.laravelProjectPath)
        .fileImporter(
            isPresented: $workspaceState.isPickingProjectFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            workspaceState.addProject(url.path)
        }
        .focusedSceneValue(\.runCodeAction, workspaceState.runOrRestartFromShortcut)
        .focusedSceneValue(\.isRunningScript, workspaceState.isRunning)
    }

    @ViewBuilder
    private func streamMenuButton(_ title: String, mode: RawStreamMode) -> some View {
        Button {
            workspaceState.rawStreamMode = mode
        } label: {
            HStack(spacing: 8) {
                Text(title)
                if workspaceState.effectiveRawStreamMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

#Preview {
    let appModel = AppModel()
    ContentView()
        .environment(appModel)
        .environment(WorkspaceState(appModel: appModel))
}
