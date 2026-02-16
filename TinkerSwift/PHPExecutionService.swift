import Foundation

struct PHPExecutionResult {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum PHPExecutionService {
    static func run(code: String, projectPath: String) async -> PHPExecutionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let projectURL = URL(fileURLWithPath: projectPath)
                let artisanURL = projectURL.appendingPathComponent("artisan")

                guard FileManager.default.fileExists(atPath: artisanURL.path()) else {
                    continuation.resume(returning: PHPExecutionResult(
                        command: "php <temp-runner-file.php>",
                        stdout: "",
                        stderr: "No artisan file found at: \(artisanURL.path())",
                        exitCode: 127
                    ))
                    return
                }

                let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let snippetFileName = ".tinkerswift_snippet_\(id).php"
                let runnerFileName = ".tinkerswift_runner_\(id).php"
                let snippetURL = projectURL.appendingPathComponent(snippetFileName)
                let runnerURL = projectURL.appendingPathComponent(runnerFileName)

                let runnerScript = """
<?php
declare(strict_types=1);

use Illuminate\\Contracts\\Console\\Kernel;

require __DIR__ . '/vendor/autoload.php';
$app = require __DIR__ . '/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

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
                    try code.write(to: snippetURL, atomically: true, encoding: .utf8)
                    try runnerScript.write(to: runnerURL, atomically: true, encoding: .utf8)
                } catch {
                    continuation.resume(returning: PHPExecutionResult(
                        command: "php \(runnerFileName)",
                        stdout: "",
                        stderr: "Failed to create temporary PHP files: \(error.localizedDescription)",
                        exitCode: 1
                    ))
                    return
                }

                let cleanupTemporaryFiles = {
                    try? FileManager.default.removeItem(at: snippetURL)
                    try? FileManager.default.removeItem(at: runnerURL)
                }

                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.currentDirectoryURL = projectURL
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["php", runnerFileName]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    cleanupTemporaryFiles()

                    continuation.resume(returning: PHPExecutionResult(
                        command: "php \(runnerFileName)",
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: process.terminationStatus
                    ))
                } catch {
                    cleanupTemporaryFiles()
                    continuation.resume(returning: PHPExecutionResult(
                        command: "php \(runnerFileName)",
                        stdout: "",
                        stderr: "Failed to run PHP process: \(error.localizedDescription)",
                        exitCode: 1
                    ))
                }
            }
        }
    }
}
