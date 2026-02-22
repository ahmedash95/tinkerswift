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

                Button(action: workspaceState.showRunHistoryWindow) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Run History")
                .disabled(!workspaceState.canShowRunHistory)

                Button(action: workspaceState.revealSelectedProjectInFinder) {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("Reveal in Finder")
                .disabled(!workspaceState.canRevealSelectedProjectInFinder)
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
        .sheet(isPresented: $workspaceState.isShowingDefaultProjectInstallSheet) {
            DefaultProjectInstallSheet()
                .environment(workspaceState)
        }
        .sheet(isPresented: $workspaceState.isShowingDockerProjectSheet) {
            DockerProjectSetupSheet()
                .environment(workspaceState)
        }
        .sheet(isPresented: $workspaceState.isShowingRenameProjectSheet) {
            RenameProjectSheet()
                .environment(workspaceState)
        }
        .sheet(isPresented: $workspaceState.isShowingSymbolSearchSheet) {
            SymbolSearchSheet()
                .environment(workspaceState)
        }
        .focusedSceneValue(\.runCodeAction, workspaceState.runOrRestartFromShortcut)
        .focusedSceneValue(\.isRunningScript, workspaceState.isRunning)
        .focusedSceneValue(\.workspaceSymbolSearchAction, workspaceState.showWorkspaceSymbolSearchFromShortcut)
        .focusedSceneValue(\.documentSymbolSearchAction, workspaceState.showDocumentSymbolSearchFromShortcut)
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

struct DockerProjectSetupSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var containers: [DockerContainerSummary] = []
    @State private var selectedContainerID = ""
    @State private var projectName = ""
    @State private var detectedProjectPath = ""
    @State private var isLoadingContainers = false
    @State private var isDetectingPath = false
    @State private var errorMessage = ""

    private var filteredContainers: [DockerContainerSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return containers }
        return containers.filter { container in
            container.name.localizedCaseInsensitiveContains(query) ||
                container.image.localizedCaseInsensitiveContains(query) ||
                container.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedContainer: DockerContainerSummary? {
        containers.first(where: { $0.id == selectedContainerID })
    }

    private var canSave: Bool {
        selectedContainer != nil &&
            !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !detectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Docker Project")
                .font(.title3.weight(.semibold))

            Text("Pick a running container, then detect or edit the Laravel project path.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Search container", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh") {
                    Task { await loadContainers() }
                }
                .disabled(isLoadingContainers)
            }

            if isLoadingContainers {
                ProgressView("Loading containers...")
                    .controlSize(.small)
            } else if filteredContainers.isEmpty {
                Text("No running containers found.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredContainers) { container in
                            Button {
                                selectedContainerID = container.id
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(container.name)
                                            .font(.body.weight(.medium))
                                        Text("\(container.image) • \(container.status)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedContainerID == container.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedContainerID == container.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 170, maxHeight: 220)
            }

            TextField("Project name", text: $projectName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Project path in container", text: $detectedProjectPath)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await detectPath() }
                } label: {
                    if isDetectingPath {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Detect Path")
                    }
                }
                .disabled(selectedContainer == nil || isDetectingPath)
            }

            if let selectedContainer {
                Text("Selected: \(selectedContainer.name) (\(selectedContainer.id.prefix(12)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Project") {
                    saveProject()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 680)
        .task {
            await loadContainers()
        }
        .onChange(of: selectedContainerID) { _, _ in
            suggestProjectNameIfNeeded()
        }
    }

    private func loadContainers() async {
        isLoadingContainers = true
        errorMessage = ""
        containers = await workspaceState.listDockerContainers()
        isLoadingContainers = false

        if selectedContainerID.isEmpty, let first = containers.first {
            selectedContainerID = first.id
            suggestProjectNameIfNeeded()
        } else if !selectedContainerID.isEmpty, !containers.contains(where: { $0.id == selectedContainerID }) {
            selectedContainerID = containers.first?.id ?? ""
            suggestProjectNameIfNeeded()
        }
    }

    private func detectPath() async {
        guard !selectedContainerID.isEmpty else { return }
        isDetectingPath = true
        errorMessage = ""
        let detected = await workspaceState.detectDockerProjectPaths(containerID: selectedContainerID)
        isDetectingPath = false
        if let first = detected.first {
            detectedProjectPath = first
            suggestProjectNameIfNeeded()
        } else {
            errorMessage = "Could not detect artisan project path automatically. Enter it manually."
        }
    }

    private func saveProject() {
        guard let selectedContainer else { return }
        let path = detectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        workspaceState.addDockerProject(container: selectedContainer, projectPath: path, displayName: projectName)
        dismiss()
    }

    private func suggestProjectNameIfNeeded() {
        guard projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let selectedContainer else { return }
        let normalizedPath = detectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPath.isEmpty {
            projectName = selectedContainer.name
            return
        }
        let tail = URL(fileURLWithPath: normalizedPath).lastPathComponent
        projectName = tail.isEmpty ? selectedContainer.name : "\(selectedContainer.name) · \(tail)"
    }
}

private struct SymbolSearchEntry: Identifiable {
    let id: String
    let name: String
    let detail: String?
    let kind: CompletionItemKind?
    let insertText: String
    let importName: String?
}

private struct SymbolSearchSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isLoading = false
    @State private var entries: [SymbolSearchEntry] = []
    @State private var selectedEntryID: String?

    var body: some View {
        @Bindable var workspaceState = workspaceState

        VStack(alignment: .leading, spacing: 12) {
            Text("Symbol Search")
                .font(.title3.weight(.semibold))

            Picker("Scope", selection: $workspaceState.symbolSearchMode) {
                Text("Workspace").tag(SymbolSearchMode.workspace)
                Text("Document").tag(SymbolSearchMode.document)
            }
            .pickerStyle(.segmented)

            TextField(
                workspaceState.symbolSearchMode == .workspace ? "Type to search workspace symbols" : "Filter document symbols",
                text: $query
            )
            .textFieldStyle(.roundedBorder)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching symbols...")
                        .foregroundStyle(.secondary)
                }
            }

            List(entries, selection: $selectedEntryID) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.kind?.paletteSymbolName ?? "textformat")
                        .foregroundStyle(entry.kind?.paletteColor ?? .secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    insert(entry)
                }
            }
            .frame(minHeight: 260)

            HStack {
                Button("Close") {
                    dismiss()
                }
                Spacer()

                Button("Copy") {
                    copySelected()
                }
                .disabled(selectedEntry == nil)

                Button("Import") {
                    importSelected()
                }
                .disabled(selectedEntry?.importName == nil)

                Button("Insert") {
                    insertSelected()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
        }
        .padding(18)
        .frame(width: 760, height: 520)
        .task {
            await reloadSymbols()
        }
        .onChange(of: workspaceState.symbolSearchMode) { _, _ in
            Task { await reloadSymbols() }
        }
        .onChange(of: query) { _, _ in
            Task { await reloadSymbols() }
        }
    }

    private var selectedEntry: SymbolSearchEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }

    private func reloadSymbols() async {
        isLoading = true
        defer { isLoading = false }

        switch workspaceState.symbolSearchMode {
        case .workspace:
            let symbols = await workspaceState.searchWorkspaceSymbols(query: query)
            entries = symbols.map { symbol in
                let importName = workspaceImportName(for: symbol)
                return SymbolSearchEntry(
                    id: "workspace:\(symbol.location?.uri ?? ""):\(symbol.location?.line ?? -1):\(symbol.name)",
                    name: symbol.name,
                    detail: symbol.detail,
                    kind: symbol.kind,
                    insertText: workspaceInsertText(for: symbol, importName: importName),
                    importName: importName
                )
            }
        case .document:
            let symbols = await workspaceState.searchDocumentSymbols(query: query)
            entries = symbols.map { symbol in
                SymbolSearchEntry(
                    id: "document:\(symbol.location?.line ?? -1):\(symbol.name)",
                    name: symbol.name,
                    detail: symbol.detail,
                    kind: symbol.kind,
                    insertText: symbol.name,
                    importName: nil
                )
            }
        }

        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = entries.first?.id
    }

    private func insertSelected() {
        guard let selectedEntry else { return }
        insert(selectedEntry)
    }

    private func insert(_ entry: SymbolSearchEntry) {
        workspaceState.insertSymbolTextAtCursor(entry.insertText)
        dismiss()
    }

    private func importSelected() {
        guard let selectedEntry, let importName = selectedEntry.importName else { return }
        workspaceState.importSymbol(name: importName, detail: nil)
        dismiss()
    }

    private func copySelected() {
        guard let selectedEntry else { return }
        workspaceState.copyTextToPasteboard(selectedEntry.importName ?? selectedEntry.insertText)
    }

    private func workspaceImportName(for symbol: WorkspaceSymbolCandidate) -> String? {
        let rawName = symbol.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawName.contains("\\") {
            return rawName
        }
        guard let detail = symbol.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              detail.contains("\\")
        else {
            return nil
        }
        if detail.hasSuffix("\\\(rawName)") {
            return detail
        }
        return "\(detail)\\\(rawName)"
    }

    private func workspaceInsertText(for symbol: WorkspaceSymbolCandidate, importName: String?) -> String {
        if let importName {
            let last = importName.split(separator: "\\").last.map(String.init)
            if let last, !last.isEmpty {
                return last
            }
        }
        let trimmed = symbol.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\\") {
            return trimmed.split(separator: "\\").last.map(String.init) ?? trimmed
        }
        return trimmed
    }
}

struct RenameProjectSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var workspaceState = workspaceState

        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Project")
                .font(.title3.weight(.semibold))

            TextField("Project name", text: $workspaceState.renamingProjectName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    workspaceState.isShowingRenameProjectSheet = false
                    dismiss()
                }
                Button("Save") {
                    workspaceState.saveProjectRename()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workspaceState.renamingProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

private extension CompletionItemKind {
    var paletteSymbolName: String {
        switch self {
        case .method:
            return "function"
        case .function:
            return "fx"
        case .constructor:
            return "wrench.and.screwdriver"
        case .field:
            return "line.3.horizontal.decrease.circle"
        case .variable:
            return "character.textbox"
        case .class:
            return "c.square"
        case .interface:
            return "square.stack.3d.up"
        case .module:
            return "shippingbox"
        case .property:
            return "slider.horizontal.3"
        case .unit:
            return "ruler"
        case .value:
            return "number"
        case .enum:
            return "list.number"
        case .keyword:
            return "captions.bubble"
        case .snippet:
            return "chevron.left.forwardslash.chevron.right"
        case .color:
            return "paintpalette"
        case .file:
            return "doc.text"
        case .reference:
            return "link"
        case .folder:
            return "folder"
        case .enumMember:
            return "list.bullet"
        case .constant:
            return "number.square"
        case .struct:
            return "cube.box"
        case .event:
            return "bolt.circle"
        case .operator:
            return "plus.slash.minus"
        case .typeParameter:
            return "tag"
        case .text:
            return "textformat"
        }
    }

    var paletteColor: Color {
        switch self {
        case .method, .function, .constructor:
            return .blue
        case .class, .interface, .struct, .enum:
            return .orange
        case .property, .field, .variable, .constant:
            return .green
        case .keyword, .operator:
            return .purple
        case .module, .file, .folder:
            return .teal
        default:
            return .secondary
        }
    }
}

private struct DefaultProjectInstallSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        VStack(alignment: .leading, spacing: 14) {
            Text("Install Default Laravel Project")
                .font(.title3.weight(.semibold))

            Text("The built-in `Default` project has not been created yet. Install it now to run snippets immediately.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Command:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("laravel new Default --database=sqlite --no-authentication --no-interaction --force")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if workspaceState.isInstallingDefaultProject {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing Default project...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !workspaceState.defaultProjectInstallErrorMessage.isEmpty {
                Text(workspaceState.defaultProjectInstallErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if !workspaceState.defaultProjectInstallOutput.isEmpty {
                ScrollView {
                    Text(workspaceState.defaultProjectInstallOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 100, maxHeight: 220)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()

                Button("Not Now") {
                    workspaceState.isShowingDefaultProjectInstallSheet = false
                }
                .disabled(workspaceState.isInstallingDefaultProject)

                Button {
                    workspaceState.installDefaultProject()
                } label: {
                    if workspaceState.isInstallingDefaultProject {
                        Text("Installing...")
                    } else {
                        Text("Install")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workspaceState.isInstallingDefaultProject)
            }
        }
        .padding(18)
        .frame(width: 620)
    }
}

#Preview {
    let appModel = AppModel()
    ContentView()
        .environment(appModel)
        .environment(WorkspaceState(appModel: appModel))
}
