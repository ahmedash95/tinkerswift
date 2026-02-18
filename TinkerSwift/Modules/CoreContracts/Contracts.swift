import Foundation

struct AppSettings: Sendable {
    var appUIScale: Double
    var showLineNumbers: Bool
    var wrapLines: Bool
    var highlightSelectedLine: Bool
    var syntaxHighlighting: Bool
    var lspCompletionEnabled: Bool
    var lspAutoTriggerEnabled: Bool
    var lspServerPathOverride: String
}

struct WorkspacePersistenceSnapshot: Sendable {
    var settings: AppSettings
    var selectedProjectPath: String
    var projects: [LaravelProject]
    var runHistory: [ProjectRunHistoryItem]
    var projectDraftsByPath: [String: String]
}

@MainActor
protocol WorkspacePersistenceStore {
    func load() -> WorkspacePersistenceSnapshot
    func save(settings: AppSettings)
    func save(projects: [LaravelProject])
    func save(runHistory: [ProjectRunHistoryItem])
    func save(projectDraftsByPath: [String: String])
    func save(selectedProjectPath: String)
}

protocol CodeExecutionProviding: Sendable {
    func run(code: String, projectPath: String) async -> PHPExecutionResult
    func stop() async
}

protocol DefaultProjectInstalling: Sendable {
    func installDefaultProject(at projectPath: String) async -> LaravelProjectInstallResult
}

enum CompletionItemKind: Int, Sendable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case `struct` = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25
}

struct CompletionTextEdit: Sendable {
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
    let newText: String
    let selectedRangeInNewText: NSRange?
}

struct CompletionCandidate: Sendable {
    let id: String
    let label: String
    let detail: String?
    let documentation: String?
    let sortText: String
    let insertText: String
    let insertSelectionRange: NSRange?
    let primaryTextEdit: CompletionTextEdit?
    let additionalTextEdits: [CompletionTextEdit]
    let kind: CompletionItemKind?
}

protocol CompletionProviding: Sendable {
    var languageID: String { get }
    func setServerPathOverride(_ value: String) async
    func openOrUpdateDocument(uri: String, projectPath: String, text: String, languageID: String) async
    func closeDocument(uri: String) async
    func completionItems(
        uri: String,
        projectPath: String,
        text: String,
        utf16Offset: Int,
        triggerCharacter: String?
    ) async -> [CompletionCandidate]
}

protocol LanguagePlugin: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedLanguageIDs: Set<String> { get }
    var completionProvider: (any CompletionProviding)? { get }
    var executionProvider: (any CodeExecutionProviding)? { get }
}
