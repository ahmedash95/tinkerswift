import Foundation

@MainActor
final class UserDefaultsWorkspaceStore: WorkspacePersistenceStore {
    private static let startupRecoveryMessage = "Failed to read saved application data. Your workspace history, cached code, and output were reset. You need to start over."

    private enum DefaultsKey {
        static let appTheme = "app.theme"
        static let appUIScale = "app.uiScale"
        static let onboardingCompleted = "app.onboardingCompleted"
        static let showLineNumbers = "editor.showLineNumbers"
        static let wrapLines = "editor.wrapLines"
        static let highlightSelectedLine = "editor.highlightSelectedLine"
        static let syntaxHighlighting = "editor.syntaxHighlighting"
        static let lspCompletionEnabled = "editor.lspCompletionEnabled"
        static let lspAutoTriggerEnabled = "editor.lspAutoTriggerEnabled"
        static let autoFormatOnRunEnabled = "editor.autoFormatOnRunEnabled"
        static let lspServerPathOverride = "editor.lspServerPathOverride"
        static let phpBinaryPathOverride = "binary.php.overridePath"
        static let dockerBinaryPathOverride = "binary.docker.overridePath"
        static let laravelBinaryPathOverride = "binary.laravel.overridePath"
        static let selectedProjectID = "workspace.selectedProjectID"
        static let projectsV2JSON = "workspace.projectsV2JSON"
        static let runHistoryV2JSON = "workspace.runHistoryV2JSON"
        static let projectDraftsByProjectIDJSON = "editor.projectDraftsByProjectIDJSON"
        static let projectOutputCacheByProjectIDJSON = "workspace.projectOutputCacheByProjectIDJSON"

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

    private let defaults: UserDefaults
    private let projectSanitizer = WorkspaceProjectPersistenceSanitizer()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorkspacePersistenceSnapshot {
        let persistedScale = decodeDouble(defaults.object(forKey: DefaultsKey.appUIScale))
        let normalizedScale = sanitizedScale(persistedScale ?? UIScaleSanitizer.defaultScale)
        if persistedScale == nil || abs((persistedScale ?? normalizedScale) - normalizedScale) > 0.000_001 {
            defaults.set(normalizedScale, forKey: DefaultsKey.appUIScale)
        }

        defaults.removeObject(forKey: DefaultsKey.legacyEditorFontSize)

        let settings = AppSettings(
            appTheme: AppTheme(rawValue: defaults.string(forKey: DefaultsKey.appTheme) ?? "") ?? .system,
            appUIScale: normalizedScale,
            hasCompletedOnboarding: defaults.object(forKey: DefaultsKey.onboardingCompleted) as? Bool ?? false,
            showLineNumbers: defaults.object(forKey: DefaultsKey.showLineNumbers) as? Bool ?? true,
            wrapLines: defaults.object(forKey: DefaultsKey.wrapLines) as? Bool ?? true,
            highlightSelectedLine: defaults.object(forKey: DefaultsKey.highlightSelectedLine) as? Bool ?? true,
            syntaxHighlighting: defaults.object(forKey: DefaultsKey.syntaxHighlighting) as? Bool ?? true,
            lspCompletionEnabled: defaults.object(forKey: DefaultsKey.lspCompletionEnabled) as? Bool ?? true,
            lspAutoTriggerEnabled: defaults.object(forKey: DefaultsKey.lspAutoTriggerEnabled) as? Bool ?? true,
            autoFormatOnRunEnabled: defaults.object(forKey: DefaultsKey.autoFormatOnRunEnabled) as? Bool ?? true,
            lspServerPathOverride: defaults.string(forKey: DefaultsKey.lspServerPathOverride) ?? "",
            phpBinaryPathOverride: defaults.string(forKey: DefaultsKey.phpBinaryPathOverride) ?? "",
            dockerBinaryPathOverride: defaults.string(forKey: DefaultsKey.dockerBinaryPathOverride) ?? "",
            laravelBinaryPathOverride: defaults.string(forKey: DefaultsKey.laravelBinaryPathOverride) ?? ""
        )

        let projectsDecode = decodeProjectsV2(from: defaults.string(forKey: DefaultsKey.projectsV2JSON) ?? "[]")
        let runHistoryDecode = decodeRunHistoryV2(from: defaults.string(forKey: DefaultsKey.runHistoryV2JSON) ?? "[]")
        let draftsDecode = decodeProjectDraftsByProjectID(
            from: defaults.string(forKey: DefaultsKey.projectDraftsByProjectIDJSON) ?? "{}"
        )
        let outputCacheDecode = decodeProjectOutputCacheByProjectID(
            from: defaults.string(forKey: DefaultsKey.projectOutputCacheByProjectIDJSON) ?? "{}"
        )

        if projectsDecode.failed || runHistoryDecode.failed || draftsDecode.failed || outputCacheDecode.failed {
            resetWorkspaceData()
            return WorkspacePersistenceSnapshot(
                settings: settings,
                selectedProjectID: "",
                projects: [],
                runHistory: [],
                projectDraftsByProjectID: [:],
                projectOutputCacheByProjectID: [:],
                startupRecoveryMessage: Self.startupRecoveryMessage
            )
        }

        var projects = projectsDecode.value
        if projects.isEmpty {
            projects = decodeLegacyProjects(from: defaults.string(forKey: DefaultsKey.legacyProjectsJSON) ?? "[]")
            if !projects.isEmpty {
                save(projects: projects)
            }
        }

        var selectedProjectID = defaults.string(forKey: DefaultsKey.selectedProjectID) ?? ""
        if selectedProjectID.isEmpty {
            let legacyPath = defaults.string(forKey: DefaultsKey.legacySelectedProjectPath) ?? ""
            let normalizedLegacyPath = projectSanitizer.normalizeLocalPath(legacyPath)
            if !normalizedLegacyPath.isEmpty {
                selectedProjectID = WorkspaceProject.local(path: normalizedLegacyPath).id
            }
        }

        if selectedProjectID.isEmpty {
            selectedProjectID = projects.first?.id ?? ""
        }

        let localPathToID = localProjectPathToIDMap(projects: projects)
        var runHistory = runHistoryDecode.value
        if runHistory.isEmpty {
            runHistory = decodeLegacyRunHistory(
                from: defaults.string(forKey: DefaultsKey.legacyRunHistoryJSON) ?? "[]",
                localPathToID: localPathToID
            )
            if !runHistory.isEmpty {
                save(runHistory: runHistory)
            }
        }

        var projectDraftsByProjectID = draftsDecode.value
        if projectDraftsByProjectID.isEmpty {
            projectDraftsByProjectID = decodeLegacyProjectDrafts(
                from: defaults.string(forKey: DefaultsKey.legacyProjectDraftsJSON) ?? "{}",
                localPathToID: localPathToID
            )
            if !projectDraftsByProjectID.isEmpty {
                save(projectDraftsByProjectID: projectDraftsByProjectID)
            }
        }

        let projectOutputCacheByProjectID = outputCacheDecode.value

        if !selectedProjectID.isEmpty {
            defaults.set(selectedProjectID, forKey: DefaultsKey.selectedProjectID)
        }

        return WorkspacePersistenceSnapshot(
            settings: settings,
            selectedProjectID: selectedProjectID,
            projects: projects,
            runHistory: runHistory,
            projectDraftsByProjectID: projectDraftsByProjectID,
            projectOutputCacheByProjectID: projectOutputCacheByProjectID,
            startupRecoveryMessage: nil
        )
    }

    func save(settings: AppSettings) {
        defaults.set(settings.appTheme.rawValue, forKey: DefaultsKey.appTheme)
        defaults.set(sanitizedScale(settings.appUIScale), forKey: DefaultsKey.appUIScale)
        defaults.set(settings.hasCompletedOnboarding, forKey: DefaultsKey.onboardingCompleted)
        defaults.set(settings.showLineNumbers, forKey: DefaultsKey.showLineNumbers)
        defaults.set(settings.wrapLines, forKey: DefaultsKey.wrapLines)
        defaults.set(settings.highlightSelectedLine, forKey: DefaultsKey.highlightSelectedLine)
        defaults.set(settings.syntaxHighlighting, forKey: DefaultsKey.syntaxHighlighting)
        defaults.set(settings.lspCompletionEnabled, forKey: DefaultsKey.lspCompletionEnabled)
        defaults.set(settings.lspAutoTriggerEnabled, forKey: DefaultsKey.lspAutoTriggerEnabled)
        defaults.set(settings.autoFormatOnRunEnabled, forKey: DefaultsKey.autoFormatOnRunEnabled)
        defaults.set(settings.lspServerPathOverride, forKey: DefaultsKey.lspServerPathOverride)
        defaults.set(settings.phpBinaryPathOverride, forKey: DefaultsKey.phpBinaryPathOverride)
        defaults.set(settings.dockerBinaryPathOverride, forKey: DefaultsKey.dockerBinaryPathOverride)
        defaults.set(settings.laravelBinaryPathOverride, forKey: DefaultsKey.laravelBinaryPathOverride)
    }

    func save(projects: [WorkspaceProject]) {
        let encoder = JSONEncoder()
        let sanitized = projects.compactMap(projectSanitizer.sanitize)
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

    func save(projectOutputCacheByProjectID: [String: ProjectOutputCacheEntry]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projectOutputCacheByProjectID),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: DefaultsKey.projectOutputCacheByProjectIDJSON)
    }

    func save(selectedProjectID: String) {
        defaults.set(selectedProjectID, forKey: DefaultsKey.selectedProjectID)
    }

    private func decodeProjectsV2(from json: String) -> DecodeResult<[WorkspaceProject]> {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([WorkspaceProject].self, from: data)
        else {
            return DecodeResult(value: [], failed: !jsonIsKnownEmptyCollection(json))
        }

        var seen = Set<String>()
        var projects: [WorkspaceProject] = []
        for original in decoded {
            guard let sanitized = projectSanitizer.sanitize(original) else { continue }
            guard seen.insert(sanitized.id).inserted else { continue }
            projects.append(sanitized)
        }
        return DecodeResult(value: projects, failed: false)
    }

    private func decodeLegacyProjects(from json: String) -> [WorkspaceProject] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LegacyProject].self, from: data)
        else {
            return []
        }

        var seen = Set<String>()
        return decoded.compactMap { project in
            let normalizedPath = projectSanitizer.normalizeLocalPath(project.path)
            guard !normalizedPath.isEmpty else { return nil }
            let item = WorkspaceProject.local(path: normalizedPath)
            guard seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    private func decodeRunHistoryV2(from json: String) -> DecodeResult<[ProjectRunHistoryItem]> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode([ProjectRunHistoryItem].self, from: data)
        else {
            return DecodeResult(value: [], failed: !jsonIsKnownEmptyCollection(json))
        }

        let filtered = decoded.filter { !$0.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return DecodeResult(value: filtered, failed: false)
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
            let normalizedPath = projectSanitizer.normalizeLocalPath(item.projectPath)
            guard let projectID = localPathToID[normalizedPath] else { return nil }
            return ProjectRunHistoryItem(
                id: item.id,
                projectID: projectID,
                code: item.code,
                executedAt: item.executedAt
            )
        }
    }

    private func decodeProjectDraftsByProjectID(from json: String) -> DecodeResult<[String: String]> {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return DecodeResult(value: [:], failed: !jsonIsKnownEmptyCollection(json))
        }

        let filtered = decoded.filter { key, _ in
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return DecodeResult(value: filtered, failed: false)
    }

    private func decodeProjectOutputCacheByProjectID(from json: String) -> DecodeResult<[String: ProjectOutputCacheEntry]> {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: ProjectOutputCacheEntry].self, from: data)
        else {
            return DecodeResult(value: [:], failed: !jsonIsKnownEmptyCollection(json))
        }

        let filtered = decoded.filter { key, _ in
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return DecodeResult(value: filtered, failed: false)
    }

    private func decodeLegacyProjectDrafts(from json: String, localPathToID: [String: String]) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        var next: [String: String] = [:]
        for (path, draft) in decoded {
            let normalizedPath = projectSanitizer.normalizeLocalPath(path)
            guard let projectID = localPathToID[normalizedPath] else { continue }
            next[projectID] = draft
        }
        return next
    }

    private func localProjectPathToIDMap(projects: [WorkspaceProject]) -> [String: String] {
        var mapping: [String: String] = [:]
        for project in projects {
            if case let .local(path) = project.connection {
                mapping[projectSanitizer.normalizeLocalPath(path)] = project.id
            }
        }
        return mapping
    }

    private func sanitizedScale(_ value: Double) -> Double {
        UIScaleSanitizer.sanitize(value)
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

    private func resetWorkspaceData() {
        let keysToClear = [
            DefaultsKey.selectedProjectID,
            DefaultsKey.projectsV2JSON,
            DefaultsKey.runHistoryV2JSON,
            DefaultsKey.projectDraftsByProjectIDJSON,
            DefaultsKey.projectOutputCacheByProjectIDJSON,
            DefaultsKey.legacySelectedProjectPath,
            DefaultsKey.legacyProjectsJSON,
            DefaultsKey.legacyRunHistoryJSON,
            DefaultsKey.legacyProjectDraftsJSON
        ]

        for key in keysToClear {
            defaults.removeObject(forKey: key)
        }
    }

    private func jsonIsKnownEmptyCollection(_ json: String) -> Bool {
        let normalized = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == "[]" || normalized == "{}"
    }
}

private struct DecodeResult<Value> {
    let value: Value
    let failed: Bool
}
