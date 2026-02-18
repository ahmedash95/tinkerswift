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
        static let laravelProjectPath = "laravel.projectPath"
        static let laravelProjectsJSON = "laravel.projectsJSON"
        static let runHistoryJSON = "laravel.runHistoryJSON"
        static let projectDraftsJSON = "editor.projectDraftsJSON"
        static let legacyEditorFontSize = "editor.fontSize"
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
            lspServerPathOverride: defaults.string(forKey: DefaultsKey.lspServerPathOverride) ?? ""
        )

        let selectedProjectPath = normalizeProjectPath(defaults.string(forKey: DefaultsKey.laravelProjectPath) ?? "")
        let projects = decodeProjects(from: defaults.string(forKey: DefaultsKey.laravelProjectsJSON) ?? "[]")
        let runHistory = decodeRunHistory(from: defaults.string(forKey: DefaultsKey.runHistoryJSON) ?? "[]")
        let projectDraftsByPath = decodeProjectDrafts(from: defaults.string(forKey: DefaultsKey.projectDraftsJSON) ?? "{}")

        return WorkspacePersistenceSnapshot(
            settings: settings,
            selectedProjectPath: selectedProjectPath,
            projects: projects,
            runHistory: runHistory,
            projectDraftsByPath: projectDraftsByPath
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
    }

    func save(projects: [LaravelProject]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projects),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.laravelProjectsJSON)
    }

    func save(runHistory: [ProjectRunHistoryItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(runHistory),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.runHistoryJSON)
    }

    func save(projectDraftsByPath: [String: String]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projectDraftsByPath),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.projectDraftsJSON)
    }

    func save(selectedProjectPath: String) {
        defaults.set(normalizeProjectPath(selectedProjectPath), forKey: DefaultsKey.laravelProjectPath)
    }

    private func decodeProjects(from json: String) -> [LaravelProject] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LaravelProject].self, from: data)
        else {
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

    private func decodeRunHistory(from json: String) -> [ProjectRunHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode([ProjectRunHistoryItem].self, from: data)
        else {
            return []
        }

        return decoded.compactMap { item in
            let normalizedPath = normalizeProjectPath(item.projectPath)
            guard !normalizedPath.isEmpty else { return nil }
            return ProjectRunHistoryItem(
                id: item.id,
                projectPath: normalizedPath,
                code: item.code,
                executedAt: item.executedAt
            )
        }
    }

    private func decodeProjectDrafts(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        var sanitized: [String: String] = [:]
        for (path, draft) in decoded {
            let normalizedPath = normalizeProjectPath(path)
            guard !normalizedPath.isEmpty else { continue }
            sanitized[normalizedPath] = draft
        }
        return sanitized
    }

    private func normalizeProjectPath(_ raw: String) -> String {
        var normalized = URL(fileURLWithPath: raw).standardizedFileURL.path
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
