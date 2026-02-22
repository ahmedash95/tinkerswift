import Foundation

struct AppSettings: Sendable {
    var appUIScale: Double
    var showLineNumbers: Bool
    var wrapLines: Bool
    var highlightSelectedLine: Bool
    var syntaxHighlighting: Bool
    var lspCompletionEnabled: Bool
    var lspAutoTriggerEnabled: Bool
    var autoFormatOnRunEnabled: Bool
    var lspServerPathOverride: String
    var phpBinaryPathOverride: String
    var dockerBinaryPathOverride: String
    var laravelBinaryPathOverride: String
}

struct WorkspacePersistenceSnapshot: Sendable {
    var settings: AppSettings
    var selectedProjectID: String
    var projects: [WorkspaceProject]
    var runHistory: [ProjectRunHistoryItem]
    var projectDraftsByProjectID: [String: String]
}

@MainActor
protocol WorkspacePersistenceStore {
    func load() -> WorkspacePersistenceSnapshot
    func save(settings: AppSettings)
    func save(projects: [WorkspaceProject])
    func save(runHistory: [ProjectRunHistoryItem])
    func save(projectDraftsByProjectID: [String: String])
    func save(selectedProjectID: String)
}
