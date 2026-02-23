import AppKit
import Foundation
import Observation
import SwiftUI

enum ResultViewMode: String, CaseIterable {
    case pretty
    case raw
}

enum SymbolSearchMode: String, CaseIterable {
    case workspace
    case document
}

enum RawStreamMode: String, CaseIterable {
    case output
    case error
    case combined

    static func resolved(_ requested: RawStreamMode, hasStdout: Bool, hasStderr: Bool) -> RawStreamMode {
        if requested == .output && !hasStdout {
            return hasStderr ? .error : .combined
        }
        if requested == .error && !hasStderr {
            return hasStdout ? .output : .combined
        }
        if requested == .combined && !(hasStdout && hasStderr) {
            return hasStdout ? .output : .error
        }
        return requested
    }
}

@MainActor
@Observable
final class AppModel {
    private let persistenceStore: any WorkspacePersistenceStore
    private let projectCatalogService: ProjectCatalogService
    private let runHistoryService: RunHistoryService
    private let draftService: EditorDraftService
    private var persistedProjectID = ""

    var appTheme: AppTheme {
        didSet { persistSettings() }
    }

    var appUIScale: Double {
        didSet {
            let normalized = Self.sanitizedScale(appUIScale)
            if appUIScale != normalized {
                appUIScale = normalized
                return
            }
            persistSettings()
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet { persistSettings() }
    }

    var showLineNumbers: Bool {
        didSet { persistSettings() }
    }

    var wrapLines: Bool {
        didSet { persistSettings() }
    }

    var highlightSelectedLine: Bool {
        didSet { persistSettings() }
    }

    var syntaxHighlighting: Bool {
        didSet { persistSettings() }
    }

    var lspCompletionEnabled: Bool {
        didSet { persistSettings() }
    }

    var lspAutoTriggerEnabled: Bool {
        didSet { persistSettings() }
    }

    var autoFormatOnRunEnabled: Bool {
        didSet { persistSettings() }
    }

    var lspServerPathOverride: String {
        didSet { persistSettings() }
    }

    var phpBinaryPathOverride: String {
        didSet { persistSettings() }
    }

    var dockerBinaryPathOverride: String {
        didSet { persistSettings() }
    }

    var laravelBinaryPathOverride: String {
        didSet { persistSettings() }
    }

    var projects: [WorkspaceProject] {
        didSet { persistenceStore.save(projects: projects) }
    }

    var runHistory: [ProjectRunHistoryItem] {
        didSet { persistenceStore.save(runHistory: runHistory) }
    }

    var projectDraftsByProjectID: [String: String] {
        didSet { persistenceStore.save(projectDraftsByProjectID: projectDraftsByProjectID) }
    }

    init(
        persistenceStore: any WorkspacePersistenceStore = UserDefaultsWorkspaceStore(),
        projectCatalogService: ProjectCatalogService = ProjectCatalogService(),
        runHistoryService: RunHistoryService = RunHistoryService(),
        draftService: EditorDraftService = EditorDraftService()
    ) {
        self.persistenceStore = persistenceStore
        self.projectCatalogService = projectCatalogService
        self.runHistoryService = runHistoryService
        self.draftService = draftService

        let snapshot = persistenceStore.load()
        let selectedProjectID = snapshot.selectedProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        appTheme = snapshot.settings.appTheme
        appUIScale = Self.sanitizedScale(snapshot.settings.appUIScale)
        hasCompletedOnboarding = snapshot.settings.hasCompletedOnboarding
        showLineNumbers = snapshot.settings.showLineNumbers
        wrapLines = snapshot.settings.wrapLines
        highlightSelectedLine = snapshot.settings.highlightSelectedLine
        syntaxHighlighting = snapshot.settings.syntaxHighlighting
        lspCompletionEnabled = snapshot.settings.lspCompletionEnabled
        lspAutoTriggerEnabled = snapshot.settings.lspAutoTriggerEnabled
        autoFormatOnRunEnabled = snapshot.settings.autoFormatOnRunEnabled
        lspServerPathOverride = snapshot.settings.lspServerPathOverride
        phpBinaryPathOverride = snapshot.settings.phpBinaryPathOverride
        dockerBinaryPathOverride = snapshot.settings.dockerBinaryPathOverride
        laravelBinaryPathOverride = snapshot.settings.laravelBinaryPathOverride
        persistedProjectID = selectedProjectID

        projects = projectCatalogService.mergedProjects(snapshot.projects, selectedProjectID: selectedProjectID)
        runHistory = snapshot.runHistory
        projectDraftsByProjectID = snapshot.projectDraftsByProjectID
    }

    var scale: CGFloat {
        CGFloat(Self.sanitizedScale(appUIScale))
    }

    var lastSelectedProjectID: String {
        persistedProjectID
    }

    func setLastSelectedProjectID(_ id: String) {
        persistedProjectID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        persistenceStore.save(selectedProjectID: persistedProjectID)
    }

    func addLocalProject(_ path: String) {
        projects = projectCatalogService.addLocalProject(path: path, to: projects)
    }

    func upsertProject(_ project: WorkspaceProject) {
        projects = projectCatalogService.upsertProject(project, in: projects)
    }

    func recordRunHistory(projectID: String, code: String, executedAt: Date = Date()) {
        runHistory = runHistoryService.record(projectID: projectID, code: code, executedAt: executedAt, in: runHistory)
    }

    func runHistory(for projectID: String) -> [ProjectRunHistoryItem] {
        runHistoryService.history(for: projectID, in: runHistory)
    }

    func editorDraft(for projectID: String) -> String? {
        draftService.draft(for: projectID, draftsByProjectID: projectDraftsByProjectID)
    }

    func setEditorDraft(_ code: String, for projectID: String) {
        projectDraftsByProjectID = draftService.settingDraft(code, for: projectID, draftsByProjectID: projectDraftsByProjectID)
    }

    private func persistSettings() {
        persistenceStore.save(
            settings: AppSettings(
                appTheme: appTheme,
                appUIScale: appUIScale,
                hasCompletedOnboarding: hasCompletedOnboarding,
                showLineNumbers: showLineNumbers,
                wrapLines: wrapLines,
                highlightSelectedLine: highlightSelectedLine,
                syntaxHighlighting: syntaxHighlighting,
                lspCompletionEnabled: lspCompletionEnabled,
                lspAutoTriggerEnabled: lspAutoTriggerEnabled,
                autoFormatOnRunEnabled: autoFormatOnRunEnabled,
                lspServerPathOverride: lspServerPathOverride,
                phpBinaryPathOverride: phpBinaryPathOverride,
                dockerBinaryPathOverride: dockerBinaryPathOverride,
                laravelBinaryPathOverride: laravelBinaryPathOverride
            )
        )
    }

    private static func sanitizedScale(_ value: Double) -> Double {
        UIScaleSanitizer.sanitize(value)
    }
}

@MainActor
@Observable
final class WorkspaceState {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let defaultCode = """
use App\\Models\\User;

$users = User::query()
    ->latest()
    ->take(5)
    ->get(['id', 'name', 'email']);

return $users->toJson();
"""

    private static let defaultProjectFolderName = "Default"

    private static let defaultProjectPath: String = {
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ahmed.tinkerswift"
        return cachesRoot
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(defaultProjectFolderName, isDirectory: true)
            .path
    }()

    let appModel: AppModel
    private let completionProviderInstance: any CompletionProviding
    private let completionDocumentFileName: String
    private let executionProvider: any CodeExecutionProviding
    private let codeFormatter: any CodeFormattingProviding
    private let defaultProjectInstaller: any DefaultProjectInstalling
    private let sshConnectionTester: any SSHConnectionTesting
    private let dockerEnvironmentService: DockerEnvironmentService
    private let defaultProject = WorkspaceProject.local(path: WorkspaceState.defaultProjectPath)
    private var historyWindowController: NSWindowController?
    private var historyWindowCloseObserver: NSObjectProtocol?

    var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    var isPickingProjectFolder = false
    var isShowingDockerProjectSheet = false
    var isShowingSSHProjectSheet = false
    var isShowingProjectEditSheet = false
    var isShowingRenameProjectSheet = false
    var isShowingSymbolSearchSheet = false
    var symbolSearchMode: SymbolSearchMode = .workspace
    var editingProjectID = ""
    var renamingProjectID = ""
    var renamingProjectName = ""
    var isRunning = false
    var isShowingDefaultProjectInstallSheet = false
    var isInstallingDefaultProject = false
    var defaultProjectInstallCommand = LaravelProjectInstaller.defaultCommand
    var defaultProjectInstallOutput = ""
    var defaultProjectInstallErrorMessage = ""
    private var pendingRestartAfterStop = false
    private var isRestoringProjectDraft = false
    private var codeRevision: UInt64 = 0
    var lastRunMetrics: RunMetrics?
    var resultViewMode: ResultViewMode = .pretty
    var rawStreamMode: RawStreamMode = .output
    var code = defaultCode {
        didSet {
            codeRevision &+= 1
            guard !isRestoringProjectDraft else { return }
            appModel.setEditorDraft(code, for: selectedProjectID)
        }
    }
    var resultMessage = "Press Run to execute code."
    var latestExecution: PHPExecutionResult?
    var selectedRunHistoryItemID: String?
    var selectedProjectID: String {
        didSet {
            appModel.setLastSelectedProjectID(selectedProjectID)
            if selectedProjectID != oldValue {
                appModel.setEditorDraft(code, for: oldValue)
                evaluateDefaultProjectSelection(showPromptIfMissing: true)
                selectedRunHistoryItemID = nil
                loadCodeDraftForCurrentProject()
            }
            updateRunHistoryWindowTitle()
        }
    }

    init(
        appModel: AppModel,
        completionProvider: any CompletionProviding = PHPLSPService(),
        executionProvider: any CodeExecutionProviding = PHPExecutionRunner(),
        codeFormatter: any CodeFormattingProviding = PintCodeFormatter(),
        defaultProjectInstaller: any DefaultProjectInstalling = LaravelProjectInstaller(),
        sshConnectionTester: any SSHConnectionTesting = SSHConnectionTester(),
        dockerEnvironmentService: DockerEnvironmentService = .shared
    ) {
        self.appModel = appModel
        completionProviderInstance = completionProvider
        completionDocumentFileName = ".tinkerswift_scratch_\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).php"
        self.executionProvider = executionProvider
        self.codeFormatter = codeFormatter
        self.defaultProjectInstaller = defaultProjectInstaller
        self.sshConnectionTester = sshConnectionTester
        self.dockerEnvironmentService = dockerEnvironmentService
        let savedProjectID = appModel.lastSelectedProjectID
        if savedProjectID.isEmpty || !([defaultProject] + appModel.projects).contains(where: { $0.id == savedProjectID }) {
            selectedProjectID = defaultProject.id
            appModel.setLastSelectedProjectID(defaultProject.id)
        } else {
            selectedProjectID = savedProjectID
        }
        loadCodeDraftForCurrentProject()
        evaluateDefaultProjectSelection(showPromptIfMissing: selectedProjectID == defaultProject.id)
    }

    deinit {
        let executionProvider = self.executionProvider
        let completionProvider = completionProviderInstance
        Task {
            await executionProvider.stop()
            await completionProvider.shutdown()
        }
    }

    var scale: CGFloat {
        appModel.scale
    }

    var showLineNumbers: Bool {
        get { appModel.showLineNumbers }
        set { appModel.showLineNumbers = newValue }
    }

    var wrapLines: Bool {
        get { appModel.wrapLines }
        set { appModel.wrapLines = newValue }
    }

    var highlightSelectedLine: Bool {
        get { appModel.highlightSelectedLine }
        set { appModel.highlightSelectedLine = newValue }
    }

    var syntaxHighlighting: Bool {
        get { appModel.syntaxHighlighting }
        set { appModel.syntaxHighlighting = newValue }
    }

    var lspCompletionEnabled: Bool {
        get { appModel.lspCompletionEnabled }
        set { appModel.lspCompletionEnabled = newValue }
    }

    var lspAutoTriggerEnabled: Bool {
        get { appModel.lspAutoTriggerEnabled }
        set { appModel.lspAutoTriggerEnabled = newValue }
    }

    var autoFormatOnRunEnabled: Bool {
        get { appModel.autoFormatOnRunEnabled }
        set { appModel.autoFormatOnRunEnabled = newValue }
    }

    var lspServerPathOverride: String {
        get { appModel.lspServerPathOverride }
        set { appModel.lspServerPathOverride = newValue }
    }

    var projects: [WorkspaceProject] {
        [defaultProject] + appModel.projects.filter { $0.id != defaultProject.id }
    }

    var selectedProject: WorkspaceProject? {
        projects.first(where: { $0.id == selectedProjectID })
    }

    var editingProject: WorkspaceProject? {
        projects.first(where: { $0.id == editingProjectID })
    }

    var selectedProjectPath: String {
        selectedProject?.path ?? ""
    }

    var selectedProjectSubtitle: String {
        selectedProject?.subtitle ?? "No project selected"
    }

    var isLSPAvailableForSelectedProject: Bool {
        guard case let .local(path)? = selectedProject?.connection else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var completionProjectPath: String {
        if case let .local(path)? = selectedProject?.connection {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return path
            }
        }
        return ""
    }

    var effectiveLSPCompletionEnabled: Bool {
        lspCompletionEnabled && isLSPAvailableForSelectedProject
    }

    var completionProvider: any CompletionProviding {
        completionProviderInstance
    }

    var completionLanguageID: String {
        completionProvider.languageID
    }

    var selectedProjectName: String {
        guard !selectedProjectID.isEmpty else { return "No project selected" }
        if let project = selectedProject {
            return project.name
        }
        return "No project selected"
    }

    var selectedProjectRunHistory: [ProjectRunHistoryItem] {
        appModel.runHistory(for: selectedProjectID)
    }

    var selectedRunHistoryItem: ProjectRunHistoryItem? {
        guard let selectedRunHistoryItemID else { return nil }
        return selectedProjectRunHistory.first(where: { $0.id == selectedRunHistoryItemID })
    }

    var resultPresentation: ExecutionPresentation {
        ExecutionResultPresenter.present(
            execution: latestExecution,
            statusMessage: resultMessage,
            isRunning: isRunning,
            fontSize: 14 * scale
        )
    }

    var resultStatusIconName: String {
        switch resultPresentation.status {
        case .idle:
            return "circle"
        case .running:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .exception:
            return "exclamationmark.octagon.fill"
        case .fatal:
            return "xmark.octagon.fill"
        case .error:
            return "xmark.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .empty:
            return "minus.circle"
        }
    }

    var resultStatusColor: Color {
        switch resultPresentation.status {
        case .idle, .running, .stopped, .empty:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .exception, .fatal, .error:
            return .red
        }
    }

    var effectiveRawStreamMode: RawStreamMode {
        RawStreamMode.resolved(
            rawStreamMode,
            hasStdout: resultPresentation.hasStdout,
            hasStderr: resultPresentation.hasStderr
        )
    }

    var rawResultText: String {
        switch effectiveRawStreamMode {
        case .output:
            return resultPresentation.rawStdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case .error:
            return resultPresentation.rawStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .combined:
            let stdout = resultPresentation.rawStdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = resultPresentation.rawStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stdout.isEmpty { return stderr }
            if stderr.isEmpty { return stdout }
            return "[STDOUT]\n\(stdout)\n\n[STDERR]\n\(stderr)"
        }
    }

    var canChooseResultStream: Bool {
        resultViewMode == .raw && (resultPresentation.hasStdout || resultPresentation.hasStderr)
    }

    var copyableResultText: String {
        if resultViewMode == .raw {
            return rawResultText
        }

        return resultPresentation.prettySections
            .map { section in
                let text = String(section.content.characters)
                return "\(section.title)\n\(text)"
            }
            .joined(separator: "\n\n")
    }

    var canCopyResultOutput: Bool {
        !copyableResultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var executionTimeText: String {
        guard let durationMs = lastRunMetrics?.durationMs else {
            return "--"
        }
        return formatDuration(durationMs)
    }

    var memoryUsageText: String {
        guard let peakMemoryBytes = lastRunMetrics?.peakMemoryBytes else {
            return "--"
        }
        return Self.memoryFormatter.string(fromByteCount: Int64(peakMemoryBytes))
    }

    var canRevealSelectedProjectInFinder: Bool {
        guard let selectedProject else { return false }
        guard case let .local(path) = selectedProject.connection else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var canShowRunHistory: Bool {
        !selectedProjectID.isEmpty
    }

    var canShowSymbolSearch: Bool {
        effectiveLSPCompletionEnabled
    }

    var isDefaultLaravelProjectInstalled: Bool {
        isLaravelProjectAvailable(at: defaultProject.path)
    }

    var showWorkspaceSymbolSearchFromShortcut: (() -> Void)? {
        guard canShowSymbolSearch else { return nil }
        return { [weak self] in
            self?.showWorkspaceSymbolSearch()
        }
    }

    var showDocumentSymbolSearchFromShortcut: (() -> Void)? {
        guard canShowSymbolSearch else { return nil }
        return { [weak self] in
            self?.showDocumentSymbolSearch()
        }
    }

    func toggleRunStop() {
        if isRunning {
            pendingRestartAfterStop = false
            stopRunningScript()
        } else {
            runCode()
        }
    }

    func runOrRestartFromShortcut() {
        if isRunning {
            pendingRestartAfterStop = true
            stopRunningScript(statusMessage: "Restarting script...")
        } else {
            runCode()
        }
    }

    func runCode() {
        guard !isRunning else { return }
        Task { [weak self] in
            await self?.executeRunCode()
        }
    }

    func installDefaultProject() {
        guard !isInstallingDefaultProject else { return }
        let installCommand = defaultProjectInstallCommand

        isInstallingDefaultProject = true
        defaultProjectInstallOutput = ""
        defaultProjectInstallErrorMessage = ""

        Task { [weak self] in
            await self?.performDefaultProjectInstallation(command: installCommand)
        }
    }

    func addLocalProject(_ path: String) {
        appModel.addLocalProject(path)
        let selected = WorkspaceProject.local(path: path)
        if appModel.projects.contains(where: { $0.id == selected.id }) {
            selectedProjectID = selected.id
        }
    }

    func addDockerProject(container: DockerContainerSummary, projectPath: String, displayName: String? = nil) {
        var project = WorkspaceProject.docker(
            containerID: container.id,
            containerName: container.name,
            projectPath: projectPath
        )
        let normalizedName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedName.isEmpty {
            project.name = normalizedName
        }
        appModel.upsertProject(project)
        selectedProjectID = project.id
    }

    func addSSHProject(
        host: String,
        port: Int,
        username: String,
        projectPath: String,
        authenticationMethod: SSHAuthenticationMethod,
        privateKeyPath: String,
        password: String,
        displayName: String? = nil
    ) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !normalizedUsername.isEmpty, !normalizedPath.isEmpty else { return }
        guard !normalizedHost.contains(where: \.isWhitespace), !normalizedUsername.contains(where: \.isWhitespace) else { return }

        var project = WorkspaceProject.ssh(
            host: normalizedHost,
            port: port,
            username: normalizedUsername,
            projectPath: normalizedPath,
            authenticationMethod: authenticationMethod,
            privateKeyPath: privateKeyPath,
            password: password
        )
        let normalizedName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedName.isEmpty {
            project.name = normalizedName
        }
        appModel.upsertProject(project)
        selectedProjectID = project.id
    }

    func testSSHConnection(
        host: String,
        port: Int,
        username: String,
        projectPath: String,
        authenticationMethod: SSHAuthenticationMethod,
        privateKeyPath: String,
        password: String
    ) async -> SSHConnectionTestResult {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !normalizedUsername.isEmpty, !normalizedPath.isEmpty else {
            return SSHConnectionTestResult(success: false, message: "Host, username, and project path are required.")
        }
        guard !normalizedHost.contains(where: \.isWhitespace), !normalizedUsername.contains(where: \.isWhitespace) else {
            return SSHConnectionTestResult(success: false, message: "Host and username must not contain spaces.")
        }

        let project = WorkspaceProject.ssh(
            host: normalizedHost,
            port: port,
            username: normalizedUsername,
            projectPath: normalizedPath,
            authenticationMethod: authenticationMethod,
            privateKeyPath: privateKeyPath,
            password: password
        )
        guard case let .ssh(config) = project.connection else {
            return SSHConnectionTestResult(success: false, message: "Invalid SSH configuration.")
        }
        return await sshConnectionTester.testConnection(config: config)
    }

    func beginRenamingProject(_ project: WorkspaceProject) {
        guard canRenameProject(project) else { return }
        renamingProjectID = project.id
        renamingProjectName = project.name
        isShowingRenameProjectSheet = true
    }

    func beginEditingProject(_ project: WorkspaceProject) {
        guard canEditProject(project) else { return }
        editingProjectID = project.id
        isShowingProjectEditSheet = true
    }

    func cancelEditingProject() {
        editingProjectID = ""
        isShowingProjectEditSheet = false
    }

    func saveProjectRename() {
        let normalizedName = renamingProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        guard let existing = appModel.projects.first(where: { $0.id == renamingProjectID }) else {
            isShowingRenameProjectSheet = false
            return
        }
        var updated = existing
        updated.name = normalizedName
        appModel.upsertProject(updated)
        isShowingRenameProjectSheet = false
    }

    func saveEditedProject(oldProjectID: String, updatedProject: WorkspaceProject) {
        guard canEditProject(updatedProject) else { return }

        appModel.projects.removeAll { $0.id == oldProjectID }
        appModel.upsertProject(updatedProject)

        if selectedProjectID == oldProjectID {
            selectedProjectID = updatedProject.id
        }

        editingProjectID = ""
        isShowingProjectEditSheet = false
    }

    func deleteProject(_ project: WorkspaceProject) {
        guard canDeleteProject(project) else { return }
        appModel.projects.removeAll { $0.id == project.id }
        if editingProjectID == project.id {
            cancelEditingProject()
        }
        if selectedProjectID == project.id {
            selectedProjectID = defaultProject.id
        }
    }

    func listDockerContainers() async -> [DockerContainerSummary] {
        await dockerEnvironmentService.listRunningContainers()
    }

    func detectDockerProjectPaths(containerID: String) async -> [String] {
        await dockerEnvironmentService.detectProjectPaths(containerID: containerID)
    }

    func copyVisibleResultToPasteboard() {
        guard canCopyResultOutput else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyableResultText, forType: .string)
        #endif
    }

    func revealSelectedProjectInFinder() {
        guard canRevealSelectedProjectInFinder else { return }
        guard let selectedProject, case let .local(path) = selectedProject.connection else { return }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        #endif
    }

    func showRunHistoryWindow() {
        guard canShowRunHistory else { return }
        selectRunHistoryItemIfNeeded()

        if let existingWindow = historyWindowController?.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = RunHistoryWindowView()
            .environment(self)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = runHistoryWindowTitle
        window.setContentSize(NSSize(width: 900, height: 560))
        window.minSize = NSSize(width: 760, height: 420)
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        historyWindowController = controller

        historyWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyWindowController = nil
                if let historyWindowCloseObserver = self.historyWindowCloseObserver {
                    NotificationCenter.default.removeObserver(historyWindowCloseObserver)
                    self.historyWindowCloseObserver = nil
                }
            }
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWorkspaceSymbolSearch() {
        guard canShowSymbolSearch else { return }
        symbolSearchMode = .workspace
        isShowingSymbolSearchSheet = true
    }

    func showDocumentSymbolSearch() {
        guard canShowSymbolSearch else { return }
        symbolSearchMode = .document
        isShowingSymbolSearchSheet = true
    }

    func searchWorkspaceSymbols(query: String) async -> [WorkspaceSymbolCandidate] {
        guard !completionProjectPath.isEmpty else { return [] }
        return await completionProvider.workspaceSymbols(projectPath: completionProjectPath, query: query)
    }

    func searchDocumentSymbols(query: String) async -> [DocumentSymbolCandidate] {
        guard !completionProjectPath.isEmpty else { return [] }
        let symbols = await completionProvider.documentSymbols(
            uri: completionDocumentURI,
            projectPath: completionProjectPath,
            text: code
        )
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return symbols }

        return symbols.filter { symbol in
            symbol.name.localizedCaseInsensitiveContains(trimmedQuery) ||
                (symbol.detail?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    func insertSymbolTextAtCursor(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let targetWindow = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow else { return }
        NotificationCenter.default.post(
            name: .tinkerSwiftInsertTextAtCursor,
            object: targetWindow,
            userInfo: ["text": trimmed]
        )
    }

    func copyTextToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        #endif
    }

    func importSymbol(name: String, detail: String?) {
        guard let fqcn = PHPSymbolImportSupport.inferFullyQualifiedSymbolName(name: name, detail: detail) else { return }
        guard let updatedCode = PHPSymbolImportSupport.insertingUseStatement(fqcn: fqcn, into: code) else { return }
        code = updatedCode
    }

    func selectRunHistoryItemIfNeeded() {
        if selectedRunHistoryItem != nil {
            return
        }
        selectedRunHistoryItemID = selectedProjectRunHistory.first?.id
    }

    func useSelectedRunHistoryItem() {
        guard let selectedRunHistoryItem else { return }
        code = selectedRunHistoryItem.code
        closeRunHistoryWindow()
    }

    private func executeRunCode() async {
        guard let selectedProject else {
            latestExecution = nil
            resultMessage = "Select a project first."
            return
        }

        if selectedProject.id == defaultProject.id && !isLaravelProjectAvailable(at: defaultProject.path) {
            latestExecution = nil
            resultMessage = "Install the Default Laravel project first."
            isShowingDefaultProjectInstallSheet = true
            return
        }

        isRunning = true
        defer {
            isRunning = false
            pendingRestartAfterStop = false
        }

        while true {
            let runCodeSnapshot = code
            let runRevisionSnapshot = codeRevision
            scheduleAutoFormatIfNeeded(
                codeSnapshot: runCodeSnapshot,
                revisionSnapshot: runRevisionSnapshot,
                project: selectedProject
            )

            resultMessage = "Running script..."
            appModel.recordRunHistory(projectID: selectedProjectID, code: runCodeSnapshot)

            let execution = await executionProvider.run(
                code: runCodeSnapshot,
                context: ExecutionContext(project: selectedProject)
            )
            latestExecution = execution

            if execution.wasStopped {
                if pendingRestartAfterStop {
                    pendingRestartAfterStop = false
                    continue
                }
                lastRunMetrics = RunMetrics(
                    durationMs: execution.durationMs,
                    peakMemoryBytes: execution.peakMemoryBytes
                )
                resultMessage = "Execution stopped."
                return
            }

            lastRunMetrics = RunMetrics(
                durationMs: execution.durationMs,
                peakMemoryBytes: execution.peakMemoryBytes
            )
            resultMessage = "Execution completed."
            return
        }
    }

    private func stopRunningScript(statusMessage: String = "Stopping script...") {
        let executionProvider = self.executionProvider
        Task {
            await executionProvider.stop()
        }
        resultMessage = statusMessage
    }

    private func scheduleAutoFormatIfNeeded(
        codeSnapshot: String,
        revisionSnapshot: UInt64,
        project: WorkspaceProject
    ) {
        guard autoFormatOnRunEnabled else { return }

        let formatter = codeFormatter
        Task {
            guard let formatted = await formatter.format(
                code: codeSnapshot,
                context: FormattingContext(
                    project: project,
                    fallbackProjectPath: Self.defaultProjectPath
                )
            ) else {
                return
            }

            guard codeRevision == revisionSnapshot else { return }
            guard code == codeSnapshot else { return }
            guard formatted != codeSnapshot else { return }
            code = formatted
        }
    }

    private var runHistoryWindowTitle: String {
        "Run History - \(selectedProjectName)"
    }

    private func updateRunHistoryWindowTitle() {
        historyWindowController?.window?.title = runHistoryWindowTitle
    }

    func canRenameProject(_ project: WorkspaceProject) -> Bool {
        project.id != defaultProject.id
    }

    func canEditProject(_ project: WorkspaceProject) -> Bool {
        project.id != defaultProject.id
    }

    func canDeleteProject(_ project: WorkspaceProject) -> Bool {
        project.id != defaultProject.id
    }

    private func loadCodeDraftForCurrentProject() {
        let draft = appModel.editorDraft(for: selectedProjectID) ?? Self.defaultCode
        isRestoringProjectDraft = true
        code = draft
        isRestoringProjectDraft = false
    }

    private func closeRunHistoryWindow() {
        historyWindowController?.close()
        historyWindowController = nil
        if let historyWindowCloseObserver {
            NotificationCenter.default.removeObserver(historyWindowCloseObserver)
            self.historyWindowCloseObserver = nil
        }
    }

    private func performDefaultProjectInstallation(command: String) async {
        let result = await defaultProjectInstaller.installDefaultProject(
            at: defaultProject.path,
            command: command
        )

        defaultProjectInstallOutput = result.combinedOutput
        isInstallingDefaultProject = false

        if result.wasSuccessful {
            defaultProjectInstallErrorMessage = ""
            isShowingDefaultProjectInstallSheet = false
            resultMessage = "Default Laravel project is ready."
            return
        }

        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty {
            defaultProjectInstallErrorMessage = "Failed to install Default project (exit code \(result.exitCode))."
        } else {
            defaultProjectInstallErrorMessage = stderr
        }
        isShowingDefaultProjectInstallSheet = true
    }

    private func evaluateDefaultProjectSelection(showPromptIfMissing: Bool) {
        guard appModel.hasCompletedOnboarding else {
            isShowingDefaultProjectInstallSheet = false
            return
        }

        guard selectedProjectID == defaultProject.id else {
            if !isInstallingDefaultProject {
                isShowingDefaultProjectInstallSheet = false
            }
            return
        }
        guard !isLaravelProjectAvailable(at: defaultProject.path) else {
            isShowingDefaultProjectInstallSheet = false
            defaultProjectInstallErrorMessage = ""
            return
        }

        if showPromptIfMissing {
            isShowingDefaultProjectInstallSheet = true
        }
    }

    private func isLaravelProjectAvailable(at path: String) -> Bool {
        let artisanPath = URL(fileURLWithPath: path).appendingPathComponent("artisan").path
        return FileManager.default.fileExists(atPath: artisanPath)
    }

    private func formatDuration(_ durationMs: Double) -> String {
        if durationMs < 1000 {
            return String(format: "%.0f ms", durationMs)
        }
        return String(format: "%.2f s", durationMs / 1000)
    }

    private var completionDocumentURI: String {
        guard !completionProjectPath.isEmpty else { return "" }
        return URL(fileURLWithPath: completionProjectPath, isDirectory: true)
            .appendingPathComponent(completionDocumentFileName)
            .standardizedFileURL
            .absoluteString
    }
}
