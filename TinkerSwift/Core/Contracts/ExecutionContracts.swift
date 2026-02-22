import Foundation

struct ExecutionContext: Sendable {
    let project: WorkspaceProject
}

struct FormattingContext: Sendable {
    let project: WorkspaceProject
    let fallbackProjectPath: String
}

protocol CodeExecutionProviding: Sendable {
    func run(code: String, context: ExecutionContext) async -> PHPExecutionResult
    func stop() async
}

protocol CodeFormattingProviding: Sendable {
    func format(code: String, context: FormattingContext) async -> String?
}

protocol DefaultProjectInstalling: Sendable {
    func installDefaultProject(at projectPath: String, command: String) async -> LaravelProjectInstallResult
}

struct SSHConnectionTestResult: Sendable {
    let success: Bool
    let message: String
}

protocol SSHConnectionTesting: Sendable {
    func testConnection(config: SSHProjectConfig) async -> SSHConnectionTestResult
}
