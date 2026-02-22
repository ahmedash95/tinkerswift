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
    func installDefaultProject(at projectPath: String) async -> LaravelProjectInstallResult {
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
        process.arguments = [
            "new",
            projectURL.lastPathComponent,
            "--database=sqlite",
            "--no-authentication",
            "--no-interaction",
            "--force"
        ]
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
}
