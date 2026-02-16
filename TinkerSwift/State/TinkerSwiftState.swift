import Foundation
import Observation
import SwiftUI

struct LaravelProject: Codable, Hashable, Identifiable {
    let path: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct RunMetrics {
    let durationMs: Double
    let peakMemoryBytes: UInt64
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

    private let defaults: UserDefaults

    var appUIScale: Double {
        didSet { defaults.set(appUIScale, forKey: DefaultsKey.appUIScale) }
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

        appUIScale = defaults.object(forKey: DefaultsKey.appUIScale) as? Double ?? 1.0
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
        CGFloat(max(0.6, min(appUIScale, 3.0)))
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

    let appModel: AppModel
    private let runner = PHPExecutionRunner()

    var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    var isPickingProjectFolder = false
    var isRunning = false
    var lastRunMetrics: RunMetrics?
    var code = defaultCode
    var result = "Press Run to execute code."
    var laravelProjectPath: String {
        didSet { appModel.setLastSelectedProjectPath(laravelProjectPath) }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        laravelProjectPath = appModel.lastSelectedProjectPath.isEmpty ? (appModel.projects.first?.path ?? "") : appModel.lastSelectedProjectPath
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
        appModel.projects
    }

    var selectedProjectName: String {
        guard !laravelProjectPath.isEmpty else { return "No project selected" }
        if let project = appModel.projects.first(where: { $0.path == laravelProjectPath }) {
            return project.name
        }
        return URL(fileURLWithPath: laravelProjectPath).lastPathComponent
    }

    var executionTimeText: String {
        if isRunning {
            return "Running"
        }
        guard let metrics = lastRunMetrics else {
            return "--"
        }
        return formatDuration(metrics.durationMs)
    }

    var memoryUsageText: String {
        if isRunning {
            return "--"
        }
        guard let metrics = lastRunMetrics else {
            return "--"
        }
        return Self.memoryFormatter.string(fromByteCount: Int64(metrics.peakMemoryBytes))
    }

    func toggleRunStop() {
        if isRunning {
            stopRunningScript()
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

    func addProject(_ path: String) {
        appModel.addProject(path)
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if appModel.projects.contains(where: { $0.path == normalizedPath }) {
            laravelProjectPath = normalizedPath
        }
    }

    private func executeRunCode() async {
        guard !laravelProjectPath.isEmpty else {
            result = "Select a Laravel project folder first (toolbar: plus.folder)."
            return
        }

        isRunning = true
        defer { isRunning = false }

        let execution = await runner.run(code: code, projectPath: laravelProjectPath)
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if execution.wasStopped {
            lastRunMetrics = nil
            result = "Execution stopped."
            return
        }

        if let durationMs = execution.durationMs,
           let peakMemoryBytes = execution.peakMemoryBytes {
            lastRunMetrics = RunMetrics(durationMs: durationMs, peakMemoryBytes: peakMemoryBytes)
        } else {
            lastRunMetrics = nil
        }

        if !stdout.isEmpty {
            result = execution.stdout
        } else if !stderr.isEmpty {
            result = execution.stderr
        } else if execution.exitCode != 0 {
            result = "Process failed with exit code \(execution.exitCode)."
        } else {
            result = "(empty)"
        }
    }

    private func stopRunningScript() {
        Task {
            await runner.stop()
        }
        result = "Stopping script..."
    }

    private func formatDuration(_ durationMs: Double) -> String {
        if durationMs < 1000 {
            return String(format: "%.0f ms", durationMs)
        }
        return String(format: "%.2f s", durationMs / 1000)
    }
}
