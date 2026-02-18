import Foundation

@MainActor
final class UserDefaultsWorkspaceStore: WorkspacePersistenceStore {
    private enum DefaultsKey {
        static let appUIScale = "app.uiScale"
        static let showLineNumbers = "editor.showLineNumbers"
        static let wrapLines = "editor.wrapLines"
        static let highlightSelectedLine = "editor.highlightSelectedLine"
        static let syntaxHighlighting = "editor.syntaxHighlighting"
        static let lspCompletionEnabled = "editor.lspCompletionEnabled"
        static let lspAutoTriggerEnabled = "editor.lspAutoTriggerEnabled"
        static let lspServerPathOverride = "editor.lspServerPathOverride"
        static let phpBinaryPathOverride = "binary.php.overridePath"
        static let dockerBinaryPathOverride = "binary.docker.overridePath"
        static let laravelBinaryPathOverride = "binary.laravel.overridePath"
        static let selectedProjectID = "workspace.selectedProjectID"
        static let projectsV2JSON = "workspace.projectsV2JSON"
        static let runHistoryV2JSON = "workspace.runHistoryV2JSON"
        static let projectDraftsByProjectIDJSON = "editor.projectDraftsByProjectIDJSON"

        static let legacySelectedProjectPath = "laravel.projectPath"
        static let legacyProjectsJSON = "laravel.projectsJSON"
        static let legacyRunHistoryJSON = "laravel.runHistoryJSON"
        static let legacyProjectDraftsJSON = "editor.projectDraftsJSON"
        static let legacyEditorFontSize = "editor.fontSize"
    }

    private struct LegacyProject: Codable {
        let path: String
    }

    private struct LegacyRunHistoryItem: Codable {
        let id: String
        let projectPath: String
        let code: String
        let executedAt: Date
    }

    private static let minScale = 0.6
    private static let maxScale = 3.0
    private static let defaultScale = 1.0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorkspacePersistenceSnapshot {
        let persistedScale = decodeDouble(defaults.object(forKey: DefaultsKey.appUIScale))
        let normalizedScale = sanitizedScale(persistedScale ?? Self.defaultScale)
        if persistedScale == nil || abs((persistedScale ?? normalizedScale) - normalizedScale) > 0.000_001 {
            defaults.set(normalizedScale, forKey: DefaultsKey.appUIScale)
        }

        defaults.removeObject(forKey: DefaultsKey.legacyEditorFontSize)

        let settings = AppSettings(
            appUIScale: normalizedScale,
            showLineNumbers: defaults.object(forKey: DefaultsKey.showLineNumbers) as? Bool ?? true,
            wrapLines: defaults.object(forKey: DefaultsKey.wrapLines) as? Bool ?? true,
            highlightSelectedLine: defaults.object(forKey: DefaultsKey.highlightSelectedLine) as? Bool ?? true,
            syntaxHighlighting: defaults.object(forKey: DefaultsKey.syntaxHighlighting) as? Bool ?? true,
            lspCompletionEnabled: defaults.object(forKey: DefaultsKey.lspCompletionEnabled) as? Bool ?? true,
            lspAutoTriggerEnabled: defaults.object(forKey: DefaultsKey.lspAutoTriggerEnabled) as? Bool ?? true,
            lspServerPathOverride: defaults.string(forKey: DefaultsKey.lspServerPathOverride) ?? "",
            phpBinaryPathOverride: defaults.string(forKey: DefaultsKey.phpBinaryPathOverride) ?? "",
            dockerBinaryPathOverride: defaults.string(forKey: DefaultsKey.dockerBinaryPathOverride) ?? "",
            laravelBinaryPathOverride: defaults.string(forKey: DefaultsKey.laravelBinaryPathOverride) ?? ""
        )

        var projects = decodeProjectsV2(from: defaults.string(forKey: DefaultsKey.projectsV2JSON) ?? "[]")
        if projects.isEmpty {
            projects = decodeLegacyProjects(from: defaults.string(forKey: DefaultsKey.legacyProjectsJSON) ?? "[]")
            if !projects.isEmpty {
                save(projects: projects)
            }
        }

        var selectedProjectID = defaults.string(forKey: DefaultsKey.selectedProjectID) ?? ""
        if selectedProjectID.isEmpty {
            let legacyPath = defaults.string(forKey: DefaultsKey.legacySelectedProjectPath) ?? ""
            let normalizedLegacyPath = normalizeProjectPath(legacyPath)
            if !normalizedLegacyPath.isEmpty {
                selectedProjectID = WorkspaceProject.local(path: normalizedLegacyPath).id
            }
        }

        if selectedProjectID.isEmpty {
            selectedProjectID = projects.first?.id ?? ""
        }

        let localPathToID = localProjectPathToIDMap(projects: projects)
        var runHistory = decodeRunHistoryV2(from: defaults.string(forKey: DefaultsKey.runHistoryV2JSON) ?? "[]")
        if runHistory.isEmpty {
            runHistory = decodeLegacyRunHistory(
                from: defaults.string(forKey: DefaultsKey.legacyRunHistoryJSON) ?? "[]",
                localPathToID: localPathToID
            )
            if !runHistory.isEmpty {
                save(runHistory: runHistory)
            }
        }

        var projectDraftsByProjectID = decodeProjectDraftsByProjectID(
            from: defaults.string(forKey: DefaultsKey.projectDraftsByProjectIDJSON) ?? "{}"
        )
        if projectDraftsByProjectID.isEmpty {
            projectDraftsByProjectID = decodeLegacyProjectDrafts(
                from: defaults.string(forKey: DefaultsKey.legacyProjectDraftsJSON) ?? "{}",
                localPathToID: localPathToID
            )
            if !projectDraftsByProjectID.isEmpty {
                save(projectDraftsByProjectID: projectDraftsByProjectID)
            }
        }

        if !selectedProjectID.isEmpty {
            defaults.set(selectedProjectID, forKey: DefaultsKey.selectedProjectID)
        }

        return WorkspacePersistenceSnapshot(
            settings: settings,
            selectedProjectID: selectedProjectID,
            projects: projects,
            runHistory: runHistory,
            projectDraftsByProjectID: projectDraftsByProjectID
        )
    }

    func save(settings: AppSettings) {
        defaults.set(sanitizedScale(settings.appUIScale), forKey: DefaultsKey.appUIScale)
        defaults.set(settings.showLineNumbers, forKey: DefaultsKey.showLineNumbers)
        defaults.set(settings.wrapLines, forKey: DefaultsKey.wrapLines)
        defaults.set(settings.highlightSelectedLine, forKey: DefaultsKey.highlightSelectedLine)
        defaults.set(settings.syntaxHighlighting, forKey: DefaultsKey.syntaxHighlighting)
        defaults.set(settings.lspCompletionEnabled, forKey: DefaultsKey.lspCompletionEnabled)
        defaults.set(settings.lspAutoTriggerEnabled, forKey: DefaultsKey.lspAutoTriggerEnabled)
        defaults.set(settings.lspServerPathOverride, forKey: DefaultsKey.lspServerPathOverride)
        defaults.set(settings.phpBinaryPathOverride, forKey: DefaultsKey.phpBinaryPathOverride)
        defaults.set(settings.dockerBinaryPathOverride, forKey: DefaultsKey.dockerBinaryPathOverride)
        defaults.set(settings.laravelBinaryPathOverride, forKey: DefaultsKey.laravelBinaryPathOverride)
    }

    func save(projects: [WorkspaceProject]) {
        let encoder = JSONEncoder()
        let sanitized = projects.compactMap(sanitizeProject)
        guard let data = try? encoder.encode(sanitized),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.projectsV2JSON)
    }

    func save(runHistory: [ProjectRunHistoryItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(runHistory),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.runHistoryV2JSON)
    }

    func save(projectDraftsByProjectID: [String: String]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projectDraftsByProjectID),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.projectDraftsByProjectIDJSON)
    }

    func save(selectedProjectID: String) {
        defaults.set(selectedProjectID, forKey: DefaultsKey.selectedProjectID)
    }

    private func decodeProjectsV2(from json: String) -> [WorkspaceProject] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([WorkspaceProject].self, from: data)
        else {
            return []
        }

        var seen = Set<String>()
        return decoded.compactMap { original in
            guard let sanitized = sanitizeProject(original) else { return nil }
            guard seen.insert(sanitized.id).inserted else { return nil }
            return sanitized
        }
    }

    private func decodeLegacyProjects(from json: String) -> [WorkspaceProject] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LegacyProject].self, from: data)
        else {
            return []
        }

        var seen = Set<String>()
        return decoded.compactMap { project in
            let normalizedPath = normalizeProjectPath(project.path)
            guard !normalizedPath.isEmpty else { return nil }
            let item = WorkspaceProject.local(path: normalizedPath)
            guard seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    private func decodeRunHistoryV2(from json: String) -> [ProjectRunHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode([ProjectRunHistoryItem].self, from: data)
        else {
            return []
        }

        return decoded.filter { !$0.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func decodeLegacyRunHistory(from json: String, localPathToID: [String: String]) -> [ProjectRunHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode([LegacyRunHistoryItem].self, from: data)
        else {
            return []
        }

        return decoded.compactMap { item in
            let normalizedPath = normalizeProjectPath(item.projectPath)
            guard let projectID = localPathToID[normalizedPath] else { return nil }
            return ProjectRunHistoryItem(
                id: item.id,
                projectID: projectID,
                code: item.code,
                executedAt: item.executedAt
            )
        }
    }

    private func decodeProjectDraftsByProjectID(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        return decoded.filter { key, _ in
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func decodeLegacyProjectDrafts(from json: String, localPathToID: [String: String]) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        var next: [String: String] = [:]
        for (path, draft) in decoded {
            let normalizedPath = normalizeProjectPath(path)
            guard let projectID = localPathToID[normalizedPath] else { continue }
            next[projectID] = draft
        }
        return next
    }

    private func localProjectPathToIDMap(projects: [WorkspaceProject]) -> [String: String] {
        var mapping: [String: String] = [:]
        for project in projects {
            if case let .local(path) = project.connection {
                mapping[normalizeProjectPath(path)] = project.id
            }
        }
        return mapping
    }

    private func sanitizeProject(_ project: WorkspaceProject) -> WorkspaceProject? {
        switch project.connection {
        case let .local(path):
            let normalizedPath = normalizeProjectPath(path)
            guard !normalizedPath.isEmpty else { return nil }
            let normalized = WorkspaceProject.local(path: normalizedPath, languageID: project.languageID)
            if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized
            }
            return WorkspaceProject(
                id: normalized.id,
                name: project.name,
                languageID: project.languageID,
                connection: normalized.connection
            )
        case let .docker(config):
            let containerID = config.containerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let containerName = config.containerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = normalizeDockerPath(config.projectPath)
            guard !containerID.isEmpty, !containerName.isEmpty, !projectPath.isEmpty else {
                return nil
            }
            let normalized = WorkspaceProject.docker(
                containerID: containerID,
                containerName: containerName,
                projectPath: projectPath,
                languageID: project.languageID
            )
            if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized
            }
            return WorkspaceProject(
                id: normalized.id,
                name: project.name,
                languageID: project.languageID,
                connection: normalized.connection
            )
        case let .ssh(config):
            let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = normalizeDockerPath(config.projectPath)
            guard !host.isEmpty, !projectPath.isEmpty else { return nil }
            return WorkspaceProject(
                id: "ssh:\(host):\(projectPath)",
                name: project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(host) · \(URL(fileURLWithPath: projectPath).lastPathComponent)" : project.name,
                languageID: project.languageID,
                connection: .ssh(SSHProjectConfig(host: host, projectPath: projectPath))
            )
        }
    }

    private func normalizeProjectPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        var normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized == "/" {
            return ""
        }
        return normalized
    }

    private func normalizeDockerPath(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return ""
        }
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func sanitizedScale(_ value: Double) -> Double {
        guard value.isFinite else {
            return Self.defaultScale
        }
        return min(max(value, Self.minScale), Self.maxScale)
    }

    private func decodeDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }
}
