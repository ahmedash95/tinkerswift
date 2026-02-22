import Foundation

struct RunMetrics {
    let durationMs: Double?
    let peakMemoryBytes: UInt64?
}

struct ProjectRunHistoryItem: Codable, Hashable, Identifiable {
    let id: String
    let projectID: String
    let code: String
    let executedAt: Date
}

struct LaravelProjectInstallResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let wasSuccessful: Bool

    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

actor LaravelProjectInstaller: DefaultProjectInstalling {
    static let defaultCommand = "laravel new Default --database=sqlite --no-authentication --no-interaction --force"

    func installDefaultProject(at projectPath: String, command: String) async -> LaravelProjectInstallResult {
        let projectURL = URL(fileURLWithPath: projectPath)
        let parentURL = projectURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            return LaravelProjectInstallResult(
                stdout: "",
                stderr: "Failed to create cache directory: \(error.localizedDescription)",
                exitCode: 1,
                wasSuccessful: false
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let environment = BinaryPathResolver.processEnvironment()
        guard let laravelPath = BinaryPathResolver.effectivePath(for: .laravel) else {
            return LaravelProjectInstallResult(
                stdout: "",
                stderr: "Laravel installer not found. Please install `laravel` and ensure it is available in PATH.",
                exitCode: 127,
                wasSuccessful: false
            )
        }

        process.currentDirectoryURL = parentURL
        process.environment = environment
        process.executableURL = URL(fileURLWithPath: laravelPath)
        let resolvedArguments: [String]
        switch resolvedCommandArguments(from: command, projectFolderName: projectURL.lastPathComponent) {
        case .success(let arguments):
            resolvedArguments = arguments
        case .failure(let error):
            return LaravelProjectInstallResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: 1,
                wasSuccessful: false
            )
        }
        process.arguments = resolvedArguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output: ProcessRunOutput
        do {
            output = try await ProcessRunner.runAndCapture(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } catch {
            return LaravelProjectInstallResult(
                stdout: "",
                stderr: "Failed to run `laravel new`: \(error.localizedDescription)",
                exitCode: 1,
                wasSuccessful: false
            )
        }

        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        var stderr = String(data: output.stderr, encoding: .utf8) ?? ""
        let artisanPath = projectURL.appendingPathComponent("artisan").path
        let hasArtisan = FileManager.default.fileExists(atPath: artisanPath)
        let wasSuccessful = output.terminationStatus == 0 && hasArtisan

        if output.terminationStatus == 0 && !hasArtisan {
            if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr += "\n"
            }
            stderr += "Laravel command completed, but no artisan file was found at \(artisanPath)."
        }

        return LaravelProjectInstallResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: output.terminationStatus,
            wasSuccessful: wasSuccessful
        )
    }

    private func resolvedCommandArguments(from command: String, projectFolderName: String) -> Result<[String], CommandLineValidationError> {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(
                CommandLineValidationError(
                    message: "Command cannot be empty. Example: `laravel new Default --database=sqlite --no-interaction --force`"
                )
            )
        }

        let parsedTokens: [String]
        switch ShellCommandTokenizer.tokenize(trimmed) {
        case .success(let tokens):
            parsedTokens = tokens
        case .failure(let error):
            return .failure(CommandLineValidationError(message: "Invalid command: \(error.localizedDescription)"))
        }

        var arguments = parsedTokens
        if arguments.first?.lowercased() == "laravel" {
            arguments.removeFirst()
        }

        guard !arguments.isEmpty else {
            return .failure(CommandLineValidationError(message: "Command must include arguments after `laravel`."))
        }

        guard arguments[0] == "new" else {
            return .failure(CommandLineValidationError(message: "Command must start with `new` (or `laravel new`)."))
        }

        if arguments.count == 1 {
            arguments.append(projectFolderName)
        } else if arguments[1].hasPrefix("-") {
            arguments.insert(projectFolderName, at: 1)
        } else {
            arguments[1] = projectFolderName
        }

        return .success(arguments)
    }
}

private enum ShellCommandTokenizer {
    static func tokenize(_ input: String) -> Result<[String], CommandLineValidationError> {
        var tokens: [String] = []
        var current = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var isEscaping = false

        for character in input {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                if inSingleQuotes {
                    current.append(character)
                } else {
                    isEscaping = true
                }
                continue
            }

            if character == "'" && !inDoubleQuotes {
                inSingleQuotes.toggle()
                continue
            }

            if character == "\"" && !inSingleQuotes {
                inDoubleQuotes.toggle()
                continue
            }

            if character.isWhitespace && !inSingleQuotes && !inDoubleQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if isEscaping {
            return .failure(CommandLineValidationError(message: "Trailing escape character."))
        }
        if inSingleQuotes || inDoubleQuotes {
            return .failure(CommandLineValidationError(message: "Unterminated quote."))
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        if tokens.isEmpty {
            return .failure(CommandLineValidationError(message: "No command tokens found."))
        }
        return .success(tokens)
    }
}

private struct CommandLineValidationError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
