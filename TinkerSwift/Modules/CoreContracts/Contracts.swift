import Foundation

enum ProjectConnectionKind: String, Codable, Sendable {
    case local
    case docker
    case ssh
}

struct DockerProjectConfig: Codable, Hashable, Sendable {
    var containerID: String
    var containerName: String
    var projectPath: String
}

struct SSHProjectConfig: Codable, Hashable, Sendable {
    var host: String
    var projectPath: String
}

enum ProjectConnection: Codable, Hashable, Sendable {
    case local(path: String)
    case docker(DockerProjectConfig)
    case ssh(SSHProjectConfig)

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case docker
        case ssh
    }

    var kind: ProjectConnectionKind {
        switch self {
        case .local:
            return .local
        case .docker:
            return .docker
        case .ssh:
            return .ssh
        }
    }

    var projectPath: String {
        switch self {
        case let .local(path):
            return path
        case let .docker(config):
            return config.projectPath
        case let .ssh(config):
            return config.projectPath
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ProjectConnectionKind.self, forKey: .kind)
        switch kind {
        case .local:
            let path = try container.decode(String.self, forKey: .path)
            self = .local(path: path)
        case .docker:
            let config = try container.decode(DockerProjectConfig.self, forKey: .docker)
            self = .docker(config)
        case .ssh:
            let config = try container.decode(SSHProjectConfig.self, forKey: .ssh)
            self = .ssh(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .local(path):
            try container.encode(ProjectConnectionKind.local, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .docker(config):
            try container.encode(ProjectConnectionKind.docker, forKey: .kind)
            try container.encode(config, forKey: .docker)
        case let .ssh(config):
            try container.encode(ProjectConnectionKind.ssh, forKey: .kind)
            try container.encode(config, forKey: .ssh)
        }
    }
}

struct WorkspaceProject: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var languageID: String
    var connection: ProjectConnection

    var path: String { connection.projectPath }

    var subtitle: String {
        switch connection {
        case let .local(path):
            return path
        case let .docker(config):
            return "\(config.containerName):\(config.projectPath)"
        case let .ssh(config):
            return "\(config.host):\(config.projectPath)"
        }
    }

    var isLocal: Bool {
        if case .local = connection { return true }
        return false
    }

    static func local(path: String, languageID: String = "php") -> WorkspaceProject {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return WorkspaceProject(
            id: "local:\(normalized)",
            name: URL(fileURLWithPath: normalized).lastPathComponent,
            languageID: languageID,
            connection: .local(path: normalized)
        )
    }

    static func docker(
        containerID: String,
        containerName: String,
        projectPath: String,
        languageID: String = "php"
    ) -> WorkspaceProject {
        let normalizedPath = WorkspaceProject.normalizePOSIXPath(projectPath)
        let displayPath = URL(fileURLWithPath: normalizedPath).lastPathComponent
        return WorkspaceProject(
            id: "docker:\(containerID):\(normalizedPath)",
            name: "\(containerName) · \(displayPath)",
            languageID: languageID,
            connection: .docker(
                DockerProjectConfig(
                    containerID: containerID,
                    containerName: containerName,
                    projectPath: normalizedPath
                )
            )
        )
    }

    private static func normalizePOSIXPath(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "/"
        }
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

typealias LaravelProject = WorkspaceProject

struct DockerContainerSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let image: String
    let status: String
}

struct ExecutionContext: Sendable {
    let project: WorkspaceProject
}

struct FormattingContext: Sendable {
    let project: WorkspaceProject
    let fallbackProjectPath: String
}

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

protocol CodeExecutionProviding: Sendable {
    func run(code: String, context: ExecutionContext) async -> PHPExecutionResult
    func stop() async
}

protocol CodeFormattingProviding: Sendable {
    func format(code: String, context: FormattingContext) async -> String?
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

struct SymbolLocation: Sendable {
    let uri: String
    let line: Int
    let character: Int
}

struct WorkspaceSymbolCandidate: Sendable {
    let name: String
    let detail: String?
    let kind: CompletionItemKind?
    let location: SymbolLocation?
}

struct DocumentSymbolCandidate: Sendable {
    let name: String
    let detail: String?
    let kind: CompletionItemKind?
    let location: SymbolLocation?
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
    func definitionLocation(
        uri: String,
        projectPath: String,
        text: String,
        utf16Offset: Int
    ) async -> SymbolLocation?
    func workspaceSymbols(projectPath: String, query: String) async -> [WorkspaceSymbolCandidate]
    func documentSymbols(uri: String, projectPath: String, text: String) async -> [DocumentSymbolCandidate]
}

extension CompletionProviding {
    func definitionLocation(
        uri: String,
        projectPath: String,
        text: String,
        utf16Offset: Int
    ) async -> SymbolLocation? {
        nil
    }

    func workspaceSymbols(projectPath: String, query: String) async -> [WorkspaceSymbolCandidate] {
        []
    }

    func documentSymbols(uri: String, projectPath: String, text: String) async -> [DocumentSymbolCandidate] {
        []
    }
}
