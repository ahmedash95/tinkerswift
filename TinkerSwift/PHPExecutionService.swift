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

actor PHPExecutionRunner {
    private struct RuntimeMetrics: Decodable {
        let durationMs: Double
        let peakMemoryBytes: UInt64
    }

    private var activeProcess: Process?
    private var activeRunID: UUID?
    private var stopRequestedRunIDs = Set<UUID>()

    func run(code: String, projectPath: String) async -> PHPExecutionResult {
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

        process.currentDirectoryURL = projectURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["php", runnerFileName]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let runID = UUID()

        do {
            beginActiveExecution(process: process, runID: runID)
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let runtimeMetrics = Self.readRuntimeMetrics(from: metricsURL)
            let stoppedByRequest = endActiveExecution(runID)
            let stoppedBySignal = process.terminationReason == .uncaughtSignal &&
                (process.terminationStatus == SIGTERM || process.terminationStatus == SIGINT)
            cleanupTemporaryFiles()

            return PHPExecutionResult(
                command: "php \(runnerFileName)",
                stdout: stdout,
                stderr: stderr,
                exitCode: process.terminationStatus,
                durationMs: runtimeMetrics?.durationMs,
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

    func stop() {
        if let runID = activeRunID {
            stopRequestedRunIDs.insert(runID)
        }

        guard let processToStop = activeProcess, processToStop.isRunning else { return }
        processToStop.interrupt()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            if processToStop.isRunning {
                processToStop.terminate()
            }
        }
    }

    private static func normalizedSnippet(_ rawCode: String) -> String {
        var code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)

        if let openTagRange = code.range(of: #"^\s*<\?(?:php|=)?"#, options: .regularExpression) {
            code.removeSubrange(openTagRange)
        }
        if let closeTagRange = code.range(of: #"\?>\s*$"#, options: .regularExpression) {
            code.removeSubrange(closeTagRange)
        }

        let body = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<?php\n\(body)\n"
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
