import AppKit
import Foundation
import Observation
import SwiftUI

enum ResultViewMode: String, CaseIterable {
    case pretty
    case raw
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

struct LaravelProject: Codable, Hashable, Identifiable {
    let path: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct RunMetrics {
    let durationMs: Double?
    let peakMemoryBytes: UInt64?
}

struct LaravelProjectInstallResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let wasSuccessful: Bool

    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

actor LaravelProjectInstaller {
    func installDefaultProject(at projectPath: String) async -> LaravelProjectInstallResult {
        let projectURL = URL(fileURLWithPath: projectPath)
        let parentURL = projectURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            return LaravelProjectInstallResult(
                stdout: "",
                stderr: "Failed to create cache directory: \(error.localizedDescription)",
                exitCode: 1,
                wasSuccessful: false
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.currentDirectoryURL = parentURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "laravel",
            "new",
            projectURL.lastPathComponent,
            "--database=sqlite",
            "--no-authentication",
            "--no-interaction",
            "--force"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try await runAndWaitForTermination(process)
        } catch {
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let fallbackError = stderr.isEmpty ? "Failed to run `laravel new`: \(error.localizedDescription)" : stderr

            return LaravelProjectInstallResult(
                stdout: stdout,
                stderr: fallbackError,
                exitCode: 1,
                wasSuccessful: false
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let artisanPath = projectURL.appendingPathComponent("artisan").path
        let hasArtisan = FileManager.default.fileExists(atPath: artisanPath)
        let wasSuccessful = process.terminationStatus == 0 && hasArtisan

        if process.terminationStatus == 0 && !hasArtisan {
            if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr += "\n"
            }
            stderr += "Laravel command completed, but no artisan file was found at \(artisanPath)."
        }

        return LaravelProjectInstallResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus,
            wasSuccessful: wasSuccessful
        )
    }

    private func runAndWaitForTermination(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private enum DefaultsKey {
        static let appUIScale = "app.uiScale"
        static let showLineNumbers = "editor.showLineNumbers"
        static let wrapLines = "editor.wrapLines"
        static let highlightSelectedLine = "editor.highlightSelectedLine"
        static let syntaxHighlighting = "editor.syntaxHighlighting"
        static let laravelProjectPath = "laravel.projectPath"
        static let laravelProjectsJSON = "laravel.projectsJSON"
    }

    private static let minScale = 0.6
    private static let maxScale = 3.0
    private static let defaultScale = 1.0

    private let defaults: UserDefaults

    var appUIScale: Double {
        didSet {
            let normalized = Self.sanitizedScale(appUIScale)
            if appUIScale != normalized {
                appUIScale = normalized
                return
            }
            defaults.set(normalized, forKey: DefaultsKey.appUIScale)
        }
    }

    var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: DefaultsKey.showLineNumbers) }
    }

    var wrapLines: Bool {
        didSet { defaults.set(wrapLines, forKey: DefaultsKey.wrapLines) }
    }

    var highlightSelectedLine: Bool {
        didSet { defaults.set(highlightSelectedLine, forKey: DefaultsKey.highlightSelectedLine) }
    }

    var syntaxHighlighting: Bool {
        didSet { defaults.set(syntaxHighlighting, forKey: DefaultsKey.syntaxHighlighting) }
    }

    var projects: [LaravelProject] {
        didSet { persistProjects(projects) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        appUIScale = Self.sanitizedScale(defaults.object(forKey: DefaultsKey.appUIScale) as? Double ?? Self.defaultScale)
        showLineNumbers = defaults.object(forKey: DefaultsKey.showLineNumbers) as? Bool ?? true
        wrapLines = defaults.object(forKey: DefaultsKey.wrapLines) as? Bool ?? true
        highlightSelectedLine = defaults.object(forKey: DefaultsKey.highlightSelectedLine) as? Bool ?? true
        syntaxHighlighting = defaults.object(forKey: DefaultsKey.syntaxHighlighting) as? Bool ?? true

        let savedProjectsJSON = defaults.string(forKey: DefaultsKey.laravelProjectsJSON) ?? "[]"
        var initialProjects = Self.decodeProjects(from: savedProjectsJSON)

        let savedProjectPath = Self.normalizeProjectPath(defaults.string(forKey: DefaultsKey.laravelProjectPath) ?? "")
        if !savedProjectPath.isEmpty, !initialProjects.contains(where: { $0.path == savedProjectPath }) {
            initialProjects.append(LaravelProject(path: savedProjectPath))
            initialProjects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        projects = initialProjects
    }

    var scale: CGFloat {
        CGFloat(Self.sanitizedScale(appUIScale))
    }

    var lastSelectedProjectPath: String {
        Self.normalizeProjectPath(defaults.string(forKey: DefaultsKey.laravelProjectPath) ?? "")
    }

    func setLastSelectedProjectPath(_ path: String) {
        defaults.set(Self.normalizeProjectPath(path), forKey: DefaultsKey.laravelProjectPath)
    }

    func addProject(_ path: String) {
        let normalizedPath = Self.normalizeProjectPath(path)
        guard !normalizedPath.isEmpty else { return }

        if !projects.contains(where: { $0.path == normalizedPath }) {
            projects.append(LaravelProject(path: normalizedPath))
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func persistProjects(_ projects: [LaravelProject]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projects),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        defaults.set(json, forKey: DefaultsKey.laravelProjectsJSON)
    }

    private static func decodeProjects(from json: String) -> [LaravelProject] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LaravelProject].self, from: data) else {
            return []
        }

        var seen = Set<String>()
        return decoded.compactMap { project in
            let normalizedPath = normalizeProjectPath(project.path)
            guard !normalizedPath.isEmpty else { return nil }
            guard seen.insert(normalizedPath).inserted else { return nil }
            return LaravelProject(path: normalizedPath)
        }
    }

    private static func normalizeProjectPath(_ raw: String) -> String {
        var normalized = URL(fileURLWithPath: raw).standardizedFileURL.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func sanitizedScale(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultScale
        }
        return min(max(value, minScale), maxScale)
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
    private let runner = PHPExecutionRunner()
    private let defaultProjectInstaller = LaravelProjectInstaller()
    private let defaultProject = LaravelProject(path: WorkspaceState.defaultProjectPath)

    var columnVisibility: NavigationSplitViewVisibility = .all
    var isPickingProjectFolder = false
    var isRunning = false
    var isShowingDefaultProjectInstallSheet = false
    var isInstallingDefaultProject = false
    var defaultProjectInstallOutput = ""
    var defaultProjectInstallErrorMessage = ""
    private var pendingRestartAfterStop = false
    var lastRunMetrics: RunMetrics?
    var resultViewMode: ResultViewMode = .pretty
    var rawStreamMode: RawStreamMode = .output
    var code = defaultCode
    var resultMessage = "Press Run to execute code."
    var latestExecution: PHPExecutionResult?
    var laravelProjectPath: String {
        didSet {
            appModel.setLastSelectedProjectPath(laravelProjectPath)
            if laravelProjectPath != oldValue {
                evaluateDefaultProjectSelection(showPromptIfMissing: true)
            }
        }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        let savedPath = appModel.lastSelectedProjectPath
        if savedPath.isEmpty {
            laravelProjectPath = defaultProject.path
            appModel.setLastSelectedProjectPath(defaultProject.path)
        } else {
            laravelProjectPath = savedPath
        }
        evaluateDefaultProjectSelection(showPromptIfMissing: laravelProjectPath == defaultProject.path)
    }

    deinit {
        let runner = self.runner
        Task {
            await runner.stop()
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

    var projects: [LaravelProject] {
        [defaultProject] + appModel.projects.filter { $0.path != defaultProject.path }
    }

    var selectedProjectName: String {
        guard !laravelProjectPath.isEmpty else { return "No project selected" }
        if let project = projects.first(where: { $0.path == laravelProjectPath }) {
            return project.name
        }
        return URL(fileURLWithPath: laravelProjectPath).lastPathComponent
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

        isInstallingDefaultProject = true
        defaultProjectInstallOutput = ""
        defaultProjectInstallErrorMessage = ""

        Task { [weak self] in
            await self?.performDefaultProjectInstallation()
        }
    }

    func addProject(_ path: String) {
        appModel.addProject(path)
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if appModel.projects.contains(where: { $0.path == normalizedPath }) {
            laravelProjectPath = normalizedPath
        }
    }

    func copyVisibleResultToPasteboard() {
        guard canCopyResultOutput else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyableResultText, forType: .string)
        #endif
    }

    private func executeRunCode() async {
        guard !laravelProjectPath.isEmpty else {
            latestExecution = nil
            resultMessage = "Select a Laravel project folder first (toolbar: plus.folder)."
            return
        }

        if laravelProjectPath == defaultProject.path && !isLaravelProjectAvailable(at: defaultProject.path) {
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
            resultMessage = "Running script..."

            let execution = await runner.run(code: code, projectPath: laravelProjectPath)
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
        Task {
            await runner.stop()
        }
        resultMessage = statusMessage
    }

    private func performDefaultProjectInstallation() async {
        let result = await defaultProjectInstaller.installDefaultProject(at: defaultProject.path)

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
        guard laravelProjectPath == defaultProject.path else {
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
}
