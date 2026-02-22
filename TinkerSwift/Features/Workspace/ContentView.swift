import AppKit
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
                                Label(
                                    project.name,
                                    systemImage: workspaceState.selectedProjectID == project.id ? "checkmark" : project.connection.kind.projectSymbolName
                                )
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

                    Button {
                        workspaceState.isShowingSSHProjectSheet = true
                    } label: {
                        Label("Add SSH Project", systemImage: "network")
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
        .sheet(isPresented: $workspaceState.isShowingSSHProjectSheet) {
            SSHProjectSetupSheet()
                .environment(workspaceState)
        }
        .sheet(isPresented: $workspaceState.isShowingProjectEditSheet) {
            ProjectEditSheet()
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

private struct SSHProjectSetupSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var projectPath = "/var/www/html"
    @State private var authenticationMethod: SSHAuthenticationMethod = .privateKey
    @State private var privateKeyPath = ""
    @State private var password = ""
    @State private var projectName = ""

    @State private var isTestingConnection = false
    @State private var connectionStatusMessage = ""
    @State private var errorMessage = ""

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedProjectPath: String { projectPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPrivateKeyPath: String { privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedPort: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)), (1 ... 65535).contains(value) else {
            return nil
        }
        return value
    }

    private var canSubmit: Bool {
        guard !trimmedHost.isEmpty,
              !trimmedUsername.isEmpty,
              !trimmedProjectPath.isEmpty,
              normalizedPort != nil,
              !trimmedHost.contains(where: \.isWhitespace),
              !trimmedUsername.contains(where: \.isWhitespace)
        else {
            return false
        }

        switch authenticationMethod {
        case .privateKey:
            return !trimmedPrivateKeyPath.isEmpty
        case .password:
            return !password.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add SSH Project")
                .font(.title3.weight(.semibold))

            Text("Configure connection settings, then test before saving.")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("Host (example: server.example.com)", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Picker("Authentication", selection: $authenticationMethod) {
                ForEach(SSHAuthenticationMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.segmented)

            switch authenticationMethod {
            case .privateKey:
                HStack(spacing: 8) {
                    TextField("Private key path", text: $privateKeyPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        browsePrivateKey()
                    }
                }
            case .password:
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("Laravel project path on remote host", text: $projectPath)
                .textFieldStyle(.roundedBorder)

            TextField("Project name", text: $projectName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(!canSubmit || isTestingConnection)

                if !connectionStatusMessage.isEmpty {
                    Text(connectionStatusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
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
                .disabled(!canSubmit)
            }
        }
        .padding(18)
        .frame(width: 700)
        .onAppear {
            if username.isEmpty {
                username = NSUserName()
            }
            suggestProjectNameIfNeeded()
        }
        .onChange(of: host) { _, _ in suggestProjectNameIfNeeded() }
        .onChange(of: projectPath) { _, _ in suggestProjectNameIfNeeded() }
    }

    private func saveProject() {
        guard canSubmit, let portValue = normalizedPort else {
            errorMessage = "Fill all required SSH fields before saving."
            return
        }

        workspaceState.addSSHProject(
            host: trimmedHost,
            port: portValue,
            username: trimmedUsername,
            projectPath: trimmedProjectPath,
            authenticationMethod: authenticationMethod,
            privateKeyPath: trimmedPrivateKeyPath,
            password: password,
            displayName: projectName
        )
        dismiss()
    }

    private func browsePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose Private Key"
        panel.prompt = "Use Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }

    private func testConnection() async {
        guard let portValue = normalizedPort else {
            errorMessage = "Port must be between 1 and 65535."
            return
        }

        isTestingConnection = true
        errorMessage = ""
        connectionStatusMessage = ""
        let result = await workspaceState.testSSHConnection(
            host: trimmedHost,
            port: portValue,
            username: trimmedUsername,
            projectPath: trimmedProjectPath,
            authenticationMethod: authenticationMethod,
            privateKeyPath: trimmedPrivateKeyPath,
            password: password
        )
        isTestingConnection = false

        if result.success {
            connectionStatusMessage = result.message
        } else {
            errorMessage = result.message
        }
    }

    private func suggestProjectNameIfNeeded() {
        guard projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !trimmedHost.isEmpty else { return }
        let tail = URL(fileURLWithPath: trimmedProjectPath).lastPathComponent
        let displayPath = tail.isEmpty ? trimmedProjectPath : tail
        projectName = displayPath.isEmpty ? "\(trimmedUsername)@\(trimmedHost)" : "\(trimmedUsername)@\(trimmedHost) · \(displayPath)"
    }
}

private struct ProjectEditSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var oldProjectID = ""
    @State private var projectName = ""
    @State private var connectionKind: ProjectConnectionKind = .local

    @State private var localPath = ""

    @State private var dockerContainerID = ""
    @State private var dockerContainerName = ""
    @State private var dockerProjectPath = ""

    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUsername = ""
    @State private var sshProjectPath = "/var/www/html"
    @State private var sshAuthenticationMethod: SSHAuthenticationMethod = .privateKey
    @State private var sshPrivateKeyPath = ""
    @State private var sshPassword = ""

    @State private var isTestingSSH = false
    @State private var testStatusMessage = ""
    @State private var errorMessage = ""

    private var normalizedSSHPort: Int? {
        guard let value = Int(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)), (1 ... 65535).contains(value) else {
            return nil
        }
        return value
    }

    private var canSave: Bool {
        switch connectionKind {
        case .local:
            return !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .docker:
            return !dockerContainerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !dockerContainerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !dockerProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .ssh:
            guard !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !sshProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  normalizedSSHPort != nil
            else {
                return false
            }
            switch sshAuthenticationMethod {
            case .privateKey:
                return !sshPrivateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .password:
                return !sshPassword.isEmpty
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Project")
                .font(.title3.weight(.semibold))

            if let project = workspaceState.editingProject {
                Text("Editing: \(project.name)")
                    .foregroundStyle(.secondary)

                TextField("Project name", text: $projectName)
                    .textFieldStyle(.roundedBorder)

                switch connectionKind {
                case .local:
                    TextField("Local path", text: $localPath)
                        .textFieldStyle(.roundedBorder)
                case .docker:
                    TextField("Container ID", text: $dockerContainerID)
                        .textFieldStyle(.roundedBorder)
                    TextField("Container Name", text: $dockerContainerName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Project path in container", text: $dockerProjectPath)
                        .textFieldStyle(.roundedBorder)
                case .ssh:
                    HStack(spacing: 10) {
                        TextField("Host", text: $sshHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", text: $sshPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        TextField("Username", text: $sshUsername)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    Picker("Authentication", selection: $sshAuthenticationMethod) {
                        ForEach(SSHAuthenticationMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch sshAuthenticationMethod {
                    case .privateKey:
                        HStack(spacing: 8) {
                            TextField("Private key path", text: $sshPrivateKeyPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") {
                                browsePrivateKey()
                            }
                        }
                    case .password:
                        SecureField("Password", text: $sshPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextField("Laravel project path on remote host", text: $sshProjectPath)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button {
                            Task { await testSSHConnection() }
                        } label: {
                            if isTestingSSH {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(!canSave || isTestingSSH)

                        if !testStatusMessage.isEmpty {
                            Text(testStatusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                }
            } else {
                Text("Project is no longer available.")
                    .foregroundStyle(.secondary)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    workspaceState.cancelEditingProject()
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 700)
        .onAppear {
            loadProjectIfNeeded()
        }
        .onDisappear {
            if workspaceState.isShowingProjectEditSheet {
                workspaceState.cancelEditingProject()
            }
        }
    }

    private func loadProjectIfNeeded() {
        guard !loaded, let project = workspaceState.editingProject else { return }
        loaded = true
        oldProjectID = project.id
        projectName = project.name

        switch project.connection {
        case let .local(path):
            connectionKind = .local
            localPath = path
        case let .docker(config):
            connectionKind = .docker
            dockerContainerID = config.containerID
            dockerContainerName = config.containerName
            dockerProjectPath = config.projectPath
        case let .ssh(config):
            connectionKind = .ssh
            sshHost = config.host
            sshPort = String(config.port)
            sshUsername = config.username
            sshProjectPath = config.projectPath
            sshAuthenticationMethod = config.authenticationMethod
            sshPrivateKeyPath = config.privateKeyPath
            sshPassword = config.password
        }
    }

    private func browsePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose Private Key"
        panel.prompt = "Use Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sshPrivateKeyPath = url.path
        }
    }

    private func testSSHConnection() async {
        guard let port = normalizedSSHPort else {
            errorMessage = "Port must be between 1 and 65535."
            return
        }

        isTestingSSH = true
        errorMessage = ""
        testStatusMessage = ""
        let result = await workspaceState.testSSHConnection(
            host: sshHost,
            port: port,
            username: sshUsername,
            projectPath: sshProjectPath,
            authenticationMethod: sshAuthenticationMethod,
            privateKeyPath: sshPrivateKeyPath,
            password: sshPassword
        )
        isTestingSSH = false

        if result.success {
            testStatusMessage = result.message
        } else {
            errorMessage = result.message
        }
    }

    private func save() {
        guard let current = workspaceState.editingProject else {
            workspaceState.cancelEditingProject()
            dismiss()
            return
        }
        guard canSave else {
            errorMessage = "Please complete all required fields."
            return
        }

        let normalizedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated: WorkspaceProject
        switch connectionKind {
        case .local:
            var project = WorkspaceProject.local(path: localPath, languageID: current.languageID)
            if !normalizedName.isEmpty {
                project.name = normalizedName
            }
            updated = project
        case .docker:
            var project = WorkspaceProject.docker(
                containerID: dockerContainerID,
                containerName: dockerContainerName,
                projectPath: dockerProjectPath,
                languageID: current.languageID
            )
            if !normalizedName.isEmpty {
                project.name = normalizedName
            }
            updated = project
        case .ssh:
            guard let port = normalizedSSHPort else {
                errorMessage = "Port must be between 1 and 65535."
                return
            }
            var project = WorkspaceProject.ssh(
                host: sshHost,
                port: port,
                username: sshUsername,
                projectPath: sshProjectPath,
                authenticationMethod: sshAuthenticationMethod,
                privateKeyPath: sshPrivateKeyPath,
                password: sshPassword,
                languageID: current.languageID
            )
            if !normalizedName.isEmpty {
                project.name = normalizedName
            }
            updated = project
        }

        workspaceState.saveEditedProject(oldProjectID: oldProjectID, updatedProject: updated)
        dismiss()
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

            TextField(
                "laravel new Default --database=sqlite --no-interaction --force",
                text: $workspaceState.defaultProjectInstallCommand,
                axis: .vertical
            )
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2 ... 4)
                .textFieldStyle(.roundedBorder)
                .disabled(workspaceState.isInstallingDefaultProject)

            Text("Edit command flags if your local Laravel installer supports different options.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
