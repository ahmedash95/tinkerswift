import Darwin
import Foundation

struct PHPExecutionResult {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let durationMs: Double?
    let peakMemoryBytes: UInt64?
    let wasStopped: Bool
}

actor DockerEnvironmentService {
    static let shared = DockerEnvironmentService()

    func listRunningContainers() async -> [DockerContainerSummary] {
        let result = await runDockerCommand(arguments: [
            "ps",
            "--format",
            "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
        ])

        guard result.exitCode == 0 else {
            return []
        }

        let lines = result.stdout.split(whereSeparator: \.isNewline)
        return lines.compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let image = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let status = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return DockerContainerSummary(id: id, name: name, image: image, status: status)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func detectProjectPaths(containerID: String) async -> [String] {
        let command = [
            "exec",
            containerID,
            "sh",
            "-lc",
            #"""
paths="$(pwd) /var/www/html /var/www /app /srv/app /workspace /usr/src/app /code"
for d in $paths; do
  if [ -f "$d/artisan" ]; then
    echo "$d"
  fi
done
for base in /var/www /app /workspace /srv /usr/src /code; do
  if [ -d "$base" ]; then
    find "$base" -maxdepth 4 -type f -name artisan 2>/dev/null | sed 's#/artisan$##'
  fi
done
"""#
        ]

        let result = await runDockerCommand(arguments: command)
        guard result.exitCode == 0 else {
            return []
        }

        var seen = Set<String>()
        var candidates: [String] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            var value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if !value.hasPrefix("/") {
                value = "/\(value)"
            }
            while value.count > 1 && value.hasSuffix("/") {
                value.removeLast()
            }
            guard seen.insert(value).inserted else { continue }
            candidates.append(value)
        }
        return candidates
    }

    private func runDockerCommand(arguments: [String], stdinData: Data? = nil) async -> DockerCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.environment = BinaryPathResolver.processEnvironment()
        if let dockerPath = BinaryPathResolver.effectivePath(for: .docker) {
            process.executableURL = URL(fileURLWithPath: dockerPath)
            process.arguments = arguments
        } else {
            return DockerCommandResult(
                stdout: "",
                stderr: "docker binary not found. Checked PATH=\(process.environment?["PATH"] ?? "")",
                exitCode: 127
            )
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            let output = try await ProcessRunner.runAndCapture(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                stdinData: stdinData
            )
            return DockerCommandResult(
                stdout: String(data: output.stdout, encoding: .utf8) ?? "",
                stderr: String(data: output.stderr, encoding: .utf8) ?? "",
                exitCode: output.terminationStatus
            )
        } catch {
            return DockerCommandResult(stdout: "", stderr: error.localizedDescription, exitCode: 1)
        }
    }
}

private struct DockerCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

actor PintCodeFormatter: CodeFormattingProviding {
    func format(code: String, context: FormattingContext) async -> String? {
        guard let workspacePath = formatterWorkspacePath(for: context),
              let pintPath = pintBinaryPath(in: workspacePath)
        else {
            return nil
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let tempFileName = ".tinkerswift_format_\(id).php"
        let tempFileURL = workspaceURL.appendingPathComponent(tempFileName, isDirectory: false)
        let wrappedSnippet = Self.wrappedPHP(code)

        do {
            try wrappedSnippet.write(to: tempFileURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: tempFileURL)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.currentDirectoryURL = workspaceURL
        process.environment = BinaryPathResolver.processEnvironment()
        process.executableURL = URL(fileURLWithPath: pintPath)
        process.arguments = [
            "--no-interaction",
            "--quiet",
            tempFileName
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
            return nil
        }

        guard output.terminationStatus == 0 else {
            return nil
        }

        guard let data = try? Data(contentsOf: tempFileURL),
              let formatted = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return Self.unwrappedPHP(formatted)
    }

    private func formatterWorkspacePath(for context: FormattingContext) -> String? {
        switch context.project.connection {
        case let .local(path):
            if pintBinaryPath(in: path) != nil {
                return path
            }
        case .docker, .ssh:
            break
        }

        if pintBinaryPath(in: context.fallbackProjectPath) != nil {
            return context.fallbackProjectPath
        }
        return nil
    }

    private func pintBinaryPath(in projectPath: String) -> String? {
        let candidate = URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent("vendor/bin/pint", isDirectory: false)
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func wrappedPHP(_ rawCode: String) -> String {
        let body = unwrappedPHP(rawCode)
        return "<?php\n\(body)\n"
    }

    private static func unwrappedPHP(_ rawCode: String) -> String {
        var code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)

        if let openTagRange = code.range(of: #"^\s*<\?(?:php|=)?"#, options: .regularExpression) {
            code.removeSubrange(openTagRange)
        }
        if let closeTagRange = code.range(of: #"\?>\s*$"#, options: .regularExpression) {
            code.removeSubrange(closeTagRange)
        }

        return code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

actor PHPExecutionRunner: CodeExecutionProviding {
    private struct RuntimeMetrics: Decodable {
        let durationMs: Double
        let peakMemoryBytes: UInt64
    }

    private let remoteMetricsPrefix = "__TINKERSWIFT_METRICS__"
    private var activeProcess: Process?
    private var activeRunID: UUID?
    private var stopRequestedRunIDs = Set<UUID>()

    func run(code: String, context: ExecutionContext) async -> PHPExecutionResult {
        switch context.project.connection {
        case let .local(path):
            return await runLocal(code: code, projectPath: path)
        case let .docker(config):
            return await runDocker(code: code, config: config)
        case let .ssh(config):
            return await runSSH(code: code, config: config)
        }
    }

    private func runLocal(code: String, projectPath: String) async -> PHPExecutionResult {
        let projectURL = URL(fileURLWithPath: projectPath)
        let artisanURL = projectURL.appendingPathComponent("artisan")

        guard FileManager.default.fileExists(atPath: artisanURL.path()) else {
            return PHPExecutionResult(
                command: "php <temp-runner-file.php>",
                stdout: "",
                stderr: "No artisan file found at: \(artisanURL.path())",
                exitCode: 127,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let snippetFileName = ".tinkerswift_snippet_\(id).php"
        let runnerFileName = ".tinkerswift_runner_\(id).php"
        let metricsFileName = ".tinkerswift_metrics_\(id).json"
        let snippetURL = projectURL.appendingPathComponent(snippetFileName)
        let runnerURL = projectURL.appendingPathComponent(runnerFileName)
        let metricsURL = projectURL.appendingPathComponent(metricsFileName)

        let normalizedCode = Self.normalizedSnippet(code)

        let runnerScript = """
<?php
declare(strict_types=1);

use Illuminate\\Contracts\\Console\\Kernel;

require __DIR__ . '/vendor/autoload.php';
$app = require __DIR__ . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$__tinkerswiftStart = microtime(true);
$__tinkerswiftMetricsPath = __DIR__ . '/\(metricsFileName)';
register_shutdown_function(function () use ($__tinkerswiftStart, $__tinkerswiftMetricsPath): void {
    $durationMs = (microtime(true) - $__tinkerswiftStart) * 1000.0;
    $peakMemoryBytes = memory_get_peak_usage(true);
    $metrics = json_encode([
        'durationMs' => $durationMs,
        'peakMemoryBytes' => $peakMemoryBytes,
    ]);
    if ($metrics !== false) {
        @file_put_contents($__tinkerswiftMetricsPath, $metrics);
    }
});

ob_start();
try {
    $__result = include __DIR__ . '/\(snippetFileName)';
    $__stdout = ob_get_clean();
    if ($__stdout !== '') {
        fwrite(STDOUT, $__stdout);
    }

    if ($__result !== null) {
        if (is_scalar($__result)) {
            fwrite(STDOUT, (string) $__result . PHP_EOL);
        } else {
            ob_start();
            var_dump($__result);
            fwrite(STDOUT, ob_get_clean());
        }
    }
    exit(0);
} catch (Throwable $e) {
    $__stdout = ob_get_clean();
    if ($__stdout !== '') {
        fwrite(STDOUT, $__stdout);
    }
    fwrite(STDERR, (string) $e . PHP_EOL);
    exit(1);
}
"""

        do {
            try normalizedCode.write(to: snippetURL, atomically: true, encoding: .utf8)
            try runnerScript.write(to: runnerURL, atomically: true, encoding: .utf8)
        } catch {
            return PHPExecutionResult(
                command: "php \(runnerFileName)",
                stdout: "",
                stderr: "Failed to create temporary PHP files: \(error.localizedDescription)",
                exitCode: 1,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }

        let cleanupTemporaryFiles = {
            try? FileManager.default.removeItem(at: snippetURL)
            try? FileManager.default.removeItem(at: runnerURL)
            try? FileManager.default.removeItem(at: metricsURL)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let startedAt = Date()

        guard let phpPath = BinaryPathResolver.effectivePath(for: .php) else {
            return PHPExecutionResult(
                command: "php \(runnerFileName)",
                stdout: "",
                stderr: "PHP binary not found. Please install php or add it to PATH.",
                exitCode: 127,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }

        process.currentDirectoryURL = projectURL
        process.environment = BinaryPathResolver.processEnvironment()
        process.executableURL = URL(fileURLWithPath: phpPath)
        process.arguments = [
            "-d",
            "display_errors=1",
            "-d",
            "html_errors=0",
            "-d",
            "error_reporting=E_ALL",
            runnerFileName
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let runID = UUID()

        do {
            beginActiveExecution(process: process, runID: runID)
            let output = try await ProcessRunner.runAndCapture(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
            let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
            let runtimeMetrics = Self.readRuntimeMetrics(from: metricsURL)
            let stoppedByRequest = endActiveExecution(runID)
            let stoppedBySignal = output.terminationReason == .uncaughtSignal &&
                (output.terminationStatus == SIGTERM || output.terminationStatus == SIGINT)
            let durationMs = runtimeMetrics?.durationMs ?? Date().timeIntervalSince(startedAt) * 1000.0
            cleanupTemporaryFiles()

            return PHPExecutionResult(
                command: "php \(runnerFileName)",
                stdout: stdout,
                stderr: stderr,
                exitCode: output.terminationStatus,
                durationMs: durationMs,
                peakMemoryBytes: runtimeMetrics?.peakMemoryBytes,
                wasStopped: stoppedByRequest || stoppedBySignal
            )
        } catch {
            _ = endActiveExecution(runID)
            cleanupTemporaryFiles()
            return PHPExecutionResult(
                command: "php \(runnerFileName)",
                stdout: "",
                stderr: "Failed to run PHP process: \(error.localizedDescription)",
                exitCode: 1,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }
    }

    private func runDocker(code: String, config: DockerProjectConfig) async -> PHPExecutionResult {
        let body = Self.normalizedSnippetBody(code)
        let encodedBody = Data(body.utf8).base64EncodedString()
        let script = """
<?php
declare(strict_types=1);

use Illuminate\\Contracts\\Console\\Kernel;

if (!file_exists('artisan')) {
    fwrite(STDERR, "No artisan file found in working directory: " . getcwd() . PHP_EOL);
    exit(127);
}

require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$__start = microtime(true);
$__code = base64_decode('\(encodedBody)');
if ($__code === false) {
    fwrite(STDERR, "Failed to decode snippet" . PHP_EOL);
    exit(1);
}

ob_start();
try {
    $__result = eval($__code);
    $__stdout = ob_get_clean();
    if ($__stdout !== '') {
        fwrite(STDOUT, $__stdout);
    }

    if ($__result !== null) {
        if (is_scalar($__result)) {
            fwrite(STDOUT, (string) $__result . PHP_EOL);
        } else {
            ob_start();
            var_dump($__result);
            fwrite(STDOUT, ob_get_clean());
        }
    }
    $__durationMs = (microtime(true) - $__start) * 1000.0;
    $__peakMemoryBytes = memory_get_peak_usage(true);
    fwrite(STDERR, "\(remoteMetricsPrefix)" . json_encode(['durationMs' => $__durationMs, 'peakMemoryBytes' => $__peakMemoryBytes]) . PHP_EOL);
    exit(0);
} catch (Throwable $e) {
    $__stdout = ob_get_clean();
    if ($__stdout !== '') {
        fwrite(STDOUT, $__stdout);
    }
    fwrite(STDERR, (string) $e . PHP_EOL);
    $__durationMs = (microtime(true) - $__start) * 1000.0;
    $__peakMemoryBytes = memory_get_peak_usage(true);
    fwrite(STDERR, "\(remoteMetricsPrefix)" . json_encode(['durationMs' => $__durationMs, 'peakMemoryBytes' => $__peakMemoryBytes]) . PHP_EOL);
    exit(1);
}
"""

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        guard let dockerPath = BinaryPathResolver.effectivePath(for: .docker) else {
            return PHPExecutionResult(
                command: "docker exec -i -w \(config.projectPath) \(config.containerID) php",
                stdout: "",
                stderr: "Docker binary not found. Please install docker or add it to PATH.",
                exitCode: 127,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }

        process.environment = BinaryPathResolver.processEnvironment()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = [
            "exec",
            "-i",
            "-w",
            config.projectPath,
            config.containerID,
            "php",
            "-d",
            "display_errors=1",
            "-d",
            "html_errors=0",
            "-d",
            "error_reporting=E_ALL"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let runID = UUID()
        let startedAt = Date()

        do {
            beginActiveExecution(process: process, runID: runID)
            let output = try await ProcessRunner.runAndCapture(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                stdinData: Data(script.utf8)
            )
            let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
            let rawStderr = String(data: output.stderr, encoding: .utf8) ?? ""
            let parsed = parseRemoteRuntimeMetrics(from: rawStderr)

            let stoppedByRequest = endActiveExecution(runID)
            let stoppedBySignal = output.terminationReason == .uncaughtSignal &&
                (output.terminationStatus == SIGTERM || output.terminationStatus == SIGINT)

            return PHPExecutionResult(
                command: "docker exec -i -w \(config.projectPath) \(config.containerID) php",
                stdout: stdout,
                stderr: parsed.stderr,
                exitCode: output.terminationStatus,
                durationMs: parsed.metrics?.durationMs ?? Date().timeIntervalSince(startedAt) * 1000.0,
                peakMemoryBytes: parsed.metrics?.peakMemoryBytes,
                wasStopped: stoppedByRequest || stoppedBySignal
            )
        } catch {
            _ = endActiveExecution(runID)
            return PHPExecutionResult(
                command: "docker exec -i -w \(config.projectPath) \(config.containerID) php",
                stdout: "",
                stderr: "Failed to run Docker PHP process: \(error.localizedDescription)",
                exitCode: 1,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }
    }

    private func runSSH(code: String, config: SSHProjectConfig) async -> PHPExecutionResult {
        let body = Self.normalizedSnippetBody(code)
        let encodedBody = Data(body.utf8).base64EncodedString()
        let script = """
<?php
declare(strict_types=1);

use Illuminate\\Contracts\\Console\\Kernel;

if (!file_exists('artisan')) {
    fwrite(STDERR, "No artisan file found in working directory: " . getcwd() . PHP_EOL);
    exit(127);
}

require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$__start = microtime(true);
$__code = base64_decode('\(encodedBody)');
if ($__code === false) {
    fwrite(STDERR, "Failed to decode snippet" . PHP_EOL);
    exit(1);
}

ob_start();
try {
    $__result = eval($__code);
    $__stdout = ob_get_clean();
    if ($__stdout !== '') {
        fwrite(STDOUT, $__stdout);
    }

    if ($__result !== null) {
        if (is_scalar($__result)) {
            fwrite(STDOUT, (string) $__result . PHP_EOL);
        } else {
            ob_start();
            var_dump($__result);
            fwrite(STDOUT, ob_get_clean());
        }
    }
    $__durationMs = (microtime(true) - $__start) * 1000.0;
    $__peakMemoryBytes = memory_get_peak_usage(true);
    fwrite(STDERR, "\(remoteMetricsPrefix)" . json_encode(['durationMs' => $__durationMs, 'peakMemoryBytes' => $__peakMemoryBytes]) . PHP_EOL);
    exit(0);
} catch (Throwable $e) {
    $__stdout = ob_get_clean();
    if ($__stdout !== '') {
        fwrite(STDOUT, $__stdout);
    }
    fwrite(STDERR, (string) $e . PHP_EOL);
    $__durationMs = (microtime(true) - $__start) * 1000.0;
    $__peakMemoryBytes = memory_get_peak_usage(true);
    fwrite(STDERR, "\(remoteMetricsPrefix)" . json_encode(['durationMs' => $__durationMs, 'peakMemoryBytes' => $__peakMemoryBytes]) . PHP_EOL);
    exit(1);
}
"""

        let remoteCommand = sshRemoteRunCommand(projectPath: config.projectPath)
        let invocation: SSHInvocation
        switch makeSSHInvocation(config: config, remoteCommand: remoteCommand) {
        case .success(let resolved):
            invocation = resolved
        case .failure(let error):
            return PHPExecutionResult(
                command: "ssh \(config.username)@\(config.host) <php-script>",
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: 1,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.environment = BinaryPathResolver.processEnvironment()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let runID = UUID()
        let startedAt = Date()
        let commandDescription = invocation.commandDescription

        do {
            beginActiveExecution(process: process, runID: runID)
            let output = try await ProcessRunner.runAndCapture(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                stdinData: Data(script.utf8)
            )
            let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
            let rawStderr = String(data: output.stderr, encoding: .utf8) ?? ""
            let parsed = parseRemoteRuntimeMetrics(from: rawStderr)

            let stoppedByRequest = endActiveExecution(runID)
            let stoppedBySignal = output.terminationReason == .uncaughtSignal &&
                (output.terminationStatus == SIGTERM || output.terminationStatus == SIGINT)

            return PHPExecutionResult(
                command: commandDescription,
                stdout: stdout,
                stderr: parsed.stderr,
                exitCode: output.terminationStatus,
                durationMs: parsed.metrics?.durationMs ?? Date().timeIntervalSince(startedAt) * 1000.0,
                peakMemoryBytes: parsed.metrics?.peakMemoryBytes,
                wasStopped: stoppedByRequest || stoppedBySignal
            )
        } catch {
            _ = endActiveExecution(runID)
            return PHPExecutionResult(
                command: commandDescription,
                stdout: "",
                stderr: "Failed to run SSH PHP process: \(error.localizedDescription)",
                exitCode: 1,
                durationMs: nil,
                peakMemoryBytes: nil,
                wasStopped: false
            )
        }
    }

    func stop() async {
        if let runID = activeRunID {
            stopRequestedRunIDs.insert(runID)
        }

        guard let processToStop = activeProcess, processToStop.isRunning else { return }
        let pid = processToStop.processIdentifier
        processToStop.interrupt()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            if processToStop.isRunning {
                processToStop.terminate()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                    if processToStop.isRunning {
                        kill(pid_t(pid), SIGKILL)
                    }
                }
            }
        }
    }

    private func parseRemoteRuntimeMetrics(from stderr: String) -> (stderr: String, metrics: RuntimeMetrics?) {
        var cleanedLines: [String] = []
        var metrics: RuntimeMetrics?
        for line in stderr.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix(remoteMetricsPrefix) {
                let payload = String(text.dropFirst(remoteMetricsPrefix.count))
                if let data = payload.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(RuntimeMetrics.self, from: data)
                {
                    metrics = decoded
                }
                continue
            }
            cleanedLines.append(text)
        }
        let cleaned = cleanedLines.joined(separator: "\n")
        return (stderr: cleaned, metrics: metrics)
    }

    private struct SSHInvocation {
        let executablePath: String
        let arguments: [String]
        let commandDescription: String
    }

    private struct SSHInvocationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func makeSSHInvocation(config: SSHProjectConfig, remoteCommand: String) -> Result<SSHInvocation, SSHInvocationError> {
        guard let sshPath = resolveExecutablePath(named: "ssh", preferredPaths: ["/usr/bin/ssh"]) else {
            return .failure(SSHInvocationError(message: "SSH binary not found. Expected /usr/bin/ssh or a PATH-discoverable ssh executable."))
        }

        let target = "\(config.username)@\(config.host)"
        var sshArguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=8",
            "-p", "\(config.port)"
        ]

        switch config.authenticationMethod {
        case .privateKey:
            let keyPath = (config.privateKeyPath as NSString).expandingTildeInPath
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(SSHInvocationError(message: "Private key path is required for private key authentication."))
            }
            guard FileManager.default.fileExists(atPath: keyPath) else {
                return .failure(SSHInvocationError(message: "Private key file not found at: \(keyPath)"))
            }
            sshArguments += [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
                "-i", keyPath
            ]
            sshArguments += [target, remoteCommand]
            return .success(
                SSHInvocation(
                    executablePath: sshPath,
                    arguments: sshArguments,
                    commandDescription: "ssh \(target) \"\(remoteCommand)\""
                )
            )
        case .password:
            guard !config.password.isEmpty else {
                return .failure(SSHInvocationError(message: "Password is required for password authentication."))
            }
            guard let sshpassPath = resolveExecutablePath(
                named: "sshpass",
                preferredPaths: ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]
            ) else {
                return .failure(SSHInvocationError(message: "Password authentication requires `sshpass` to be installed."))
            }
            sshArguments += [
                "-o", "BatchMode=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]
            let arguments = ["-p", config.password, sshPath] + sshArguments + [target, remoteCommand]
            return .success(
                SSHInvocation(
                    executablePath: sshpassPath,
                    arguments: arguments,
                    commandDescription: "sshpass -p ***** ssh \(target) \"\(remoteCommand)\""
                )
            )
        }
    }

    private func sshRemoteRunCommand(projectPath: String) -> String {
        let quotedPath = Self.shellSingleQuoted(projectPath)
        return "cd \(quotedPath) && php -d display_errors=1 -d html_errors=0 -d error_reporting=E_ALL"
    }

    private func resolveExecutablePath(named binary: String, preferredPaths: [String] = []) -> String? {
        for path in preferredPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let pathValue = BinaryPathResolver.processEnvironment()["PATH"] ?? ""
        for entry in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent(binary)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func normalizedSnippet(_ rawCode: String) -> String {
        let body = normalizedSnippetBody(rawCode)
        return "<?php\n\(body)\n"
    }

    private static func normalizedSnippetBody(_ rawCode: String) -> String {
        var code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)

        if let openTagRange = code.range(of: #"^\s*<\?(?:php|=)?"#, options: .regularExpression) {
            code.removeSubrange(openTagRange)
        }
        if let closeTagRange = code.range(of: #"\?>\s*$"#, options: .regularExpression) {
            code.removeSubrange(closeTagRange)
        }

        return code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readRuntimeMetrics(from url: URL) -> RuntimeMetrics? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(RuntimeMetrics.self, from: data)
    }

    private func beginActiveExecution(process: Process, runID: UUID) {
        activeProcess = process
        activeRunID = runID
    }

    @discardableResult
    private func endActiveExecution(_ runID: UUID) -> Bool {
        let wasStopped = stopRequestedRunIDs.remove(runID) != nil
        if activeRunID == runID {
            activeRunID = nil
            activeProcess = nil
        }
        return wasStopped
    }
}

actor SSHConnectionTester: SSHConnectionTesting {
    private let runner = PHPExecutionRunner()

    func testConnection(config: SSHProjectConfig) async -> SSHConnectionTestResult {
        let project = WorkspaceProject(
            id: "ssh:test:\(UUID().uuidString)",
            name: "SSH Test",
            languageID: "php",
            connection: .ssh(config)
        )
        let result = await runner.run(code: "return 'ok';", context: ExecutionContext(project: project))

        if result.exitCode == 0 {
            return SSHConnectionTestResult(success: true, message: "Connection successful.")
        }

        let errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty {
            return SSHConnectionTestResult(success: false, message: errorText)
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            return SSHConnectionTestResult(success: false, message: output)
        }

        return SSHConnectionTestResult(
            success: false,
            message: "Connection test failed (exit code \(result.exitCode))."
        )
    }
}
