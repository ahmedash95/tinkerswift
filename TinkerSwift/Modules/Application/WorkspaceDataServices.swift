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

    func mergedProjects(_ persistedProjects: [WorkspaceProject], selectedProjectID: String) -> [WorkspaceProject] {
        var projects = persistedProjects

        if !selectedProjectID.isEmpty,
           !projects.contains(where: { $0.id == selectedProjectID }),
           selectedProjectID.hasPrefix("local:")
        {
            let normalizedPath = normalizeProjectID(selectedProjectID)
            if !normalizedPath.isEmpty {
                projects.append(.local(path: normalizedPath))
            }
        }
        return sortedProjects(projects)
    }

    func addLocalProject(path: String, to projects: [WorkspaceProject]) -> [WorkspaceProject] {
        let normalizedPath = normalizer.normalizeProjectPath(path)
        guard !normalizedPath.isEmpty else { return projects }
        let candidate = WorkspaceProject.local(path: normalizedPath)
        guard !projects.contains(where: { $0.id == candidate.id }) else { return projects }

        var next = projects
        next.append(candidate)
        return sortedProjects(next)
    }

    func upsertProject(_ project: WorkspaceProject, in projects: [WorkspaceProject]) -> [WorkspaceProject] {
        var next = projects
        if let index = next.firstIndex(where: { $0.id == project.id }) {
            next[index] = project
        } else {
            next.append(project)
        }
        return sortedProjects(next)
    }

    func normalize(_ path: String) -> String {
        normalizer.normalizeProjectPath(path)
    }

    private func sortedProjects(_ projects: [WorkspaceProject]) -> [WorkspaceProject] {
        projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func normalizeProjectID(_ id: String) -> String {
        guard id.hasPrefix("local:") else { return "" }
        let rawPath = String(id.dropFirst("local:".count))
        return normalizer.normalizeProjectPath(rawPath)
    }
}

@MainActor
struct RunHistoryService {
    let maxPerProject: Int

    init(maxPerProject: Int = 100) {
        self.maxPerProject = maxPerProject
    }

    func record(projectID: String, code: String, executedAt: Date, in history: [ProjectRunHistoryItem]) -> [ProjectRunHistoryItem] {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else { return history }

        let historyEntry = ProjectRunHistoryItem(
            id: UUID().uuidString,
            projectID: normalizedProjectID,
            code: code,
            executedAt: executedAt
        )

        var currentProjectHistory = history.filter { $0.projectID == normalizedProjectID }
        currentProjectHistory.insert(historyEntry, at: 0)

        if currentProjectHistory.count > maxPerProject {
            currentProjectHistory = Array(currentProjectHistory.prefix(maxPerProject))
        }

        let otherProjectsHistory = history.filter { $0.projectID != normalizedProjectID }
        return otherProjectsHistory + currentProjectHistory
    }

    func history(for projectID: String, in history: [ProjectRunHistoryItem]) -> [ProjectRunHistoryItem] {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else { return [] }

        return history
            .filter { $0.projectID == normalizedProjectID }
            .sorted { $0.executedAt > $1.executedAt }
    }
}

@MainActor
struct EditorDraftService {
    func draft(for projectID: String, draftsByProjectID: [String: String]) -> String? {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else { return nil }
        return draftsByProjectID[normalizedProjectID]
    }

    func settingDraft(_ code: String, for projectID: String, draftsByProjectID: [String: String]) -> [String: String] {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else { return draftsByProjectID }

        var next = draftsByProjectID
        next[normalizedProjectID] = code
        return next
    }
}
