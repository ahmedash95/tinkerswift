import Foundation

struct ProcessRunOutput {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let terminationReason: Process.TerminationReason
}

enum ProcessRunner {
    private final class OutputAccumulator: @unchecked Sendable {
        private var stdout = Data()
        private var stderr = Data()
        private let lock = NSLock()

        func appendStdout(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            stdout.append(data)
            lock.unlock()
        }

        func appendStderr(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            stderr.append(data)
            lock.unlock()
        }

        func snapshot() -> (stdout: Data, stderr: Data) {
            lock.lock()
            let output = (stdout, stderr)
            lock.unlock()
            return output
        }
    }

    static func runAndCapture(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdinData: Data? = nil
    ) async throws -> ProcessRunOutput {
        let accumulator = OutputAccumulator()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            accumulator.appendStdout(data)
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            accumulator.appendStderr(data)
        }

        do {
            try await waitForTermination(of: process, stdinData: stdinData)
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        process.terminationHandler = nil

        accumulator.appendStdout(stdoutHandle.readDataToEndOfFile())
        accumulator.appendStderr(stderrHandle.readDataToEndOfFile())

        let snapshot = accumulator.snapshot()
        return ProcessRunOutput(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            terminationStatus: process.terminationStatus,
            terminationReason: process.terminationReason
        )
    }

    private static func waitForTermination(of process: Process, stdinData: Data?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }

            if let stdinPipe = process.standardInput as? Pipe {
                if let stdinData {
                    stdinPipe.fileHandleForWriting.write(stdinData)
                }
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }
    }
}
