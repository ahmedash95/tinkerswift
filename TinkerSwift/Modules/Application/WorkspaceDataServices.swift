import Foundation

@MainActor
struct WorkspacePathNormalizer {
    func normalizeProjectPath(_ raw: String) -> String {
        var normalized = URL(fileURLWithPath: raw).standardizedFileURL.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

@MainActor
struct ProjectCatalogService {
    private let normalizer = WorkspacePathNormalizer()

    func mergedProjects(_ persistedProjects: [LaravelProject], selectedProjectPath: String) -> [LaravelProject] {
        var projects = persistedProjects
        let normalizedSelection = normalizer.normalizeProjectPath(selectedProjectPath)
        if !normalizedSelection.isEmpty, !projects.contains(where: { $0.path == normalizedSelection }) {
            projects.append(LaravelProject(path: normalizedSelection))
        }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return projects
    }

    func addProject(path: String, to projects: [LaravelProject]) -> [LaravelProject] {
        let normalizedPath = normalizer.normalizeProjectPath(path)
        guard !normalizedPath.isEmpty else { return projects }
        guard !projects.contains(where: { $0.path == normalizedPath }) else { return projects }

        var next = projects
        next.append(LaravelProject(path: normalizedPath))
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return next
    }

    func normalize(_ path: String) -> String {
        normalizer.normalizeProjectPath(path)
    }
}

@MainActor
struct RunHistoryService {
    let maxPerProject: Int
    private let normalizer = WorkspacePathNormalizer()

    init(maxPerProject: Int = 100) {
        self.maxPerProject = maxPerProject
    }

    func record(projectPath: String, code: String, executedAt: Date, in history: [ProjectRunHistoryItem]) -> [ProjectRunHistoryItem] {
        let normalizedPath = normalizer.normalizeProjectPath(projectPath)
        guard !normalizedPath.isEmpty else { return history }

        let historyEntry = ProjectRunHistoryItem(
            id: UUID().uuidString,
            projectPath: normalizedPath,
            code: code,
            executedAt: executedAt
        )

        var currentProjectHistory = history.filter { $0.projectPath == normalizedPath }
        currentProjectHistory.insert(historyEntry, at: 0)

        if currentProjectHistory.count > maxPerProject {
            currentProjectHistory = Array(currentProjectHistory.prefix(maxPerProject))
        }

        let otherProjectsHistory = history.filter { $0.projectPath != normalizedPath }
        return otherProjectsHistory + currentProjectHistory
    }

    func history(for projectPath: String, in history: [ProjectRunHistoryItem]) -> [ProjectRunHistoryItem] {
        let normalizedPath = normalizer.normalizeProjectPath(projectPath)
        guard !normalizedPath.isEmpty else { return [] }

        return history
            .filter { $0.projectPath == normalizedPath }
            .sorted { $0.executedAt > $1.executedAt }
    }
}

@MainActor
struct EditorDraftService {
    private let normalizer = WorkspacePathNormalizer()

    func draft(for projectPath: String, draftsByPath: [String: String]) -> String? {
        let normalizedPath = normalizer.normalizeProjectPath(projectPath)
        guard !normalizedPath.isEmpty else { return nil }
        return draftsByPath[normalizedPath]
    }

    func settingDraft(_ code: String, for projectPath: String, draftsByPath: [String: String]) -> [String: String] {
        let normalizedPath = normalizer.normalizeProjectPath(projectPath)
        guard !normalizedPath.isEmpty else { return draftsByPath }

        var next = draftsByPath
        next[normalizedPath] = code
        return next
    }
}
