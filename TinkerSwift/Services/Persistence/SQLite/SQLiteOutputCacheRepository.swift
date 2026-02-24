import Foundation
import SQLite3

final class SQLiteOutputCacheRepository {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func load() throws -> [String: ProjectOutputCacheEntry] {
        let statement = try database.prepare(
            """
            SELECT
                project_id,
                command,
                stdout,
                stderr,
                exit_code,
                duration_ms,
                peak_memory_bytes,
                was_stopped,
                result_message
            FROM workspace_project_output_cache;
            """
        )

        var outputByProjectID: [String: ProjectOutputCacheEntry] = [:]

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let projectID = statement.columnText(at: 0),
                  let command = statement.columnText(at: 1),
                  let stdout = statement.columnText(at: 2),
                  let stderr = statement.columnText(at: 3),
                  let resultMessage = statement.columnText(at: 8)
            else {
                throw SQLiteStoreError.invalidData("workspace_project_output_cache contains invalid rows.")
            }

            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProjectID.isEmpty else { continue }

            let durationMs: Double?
            if statement.columnType(at: 5) == SQLITE_NULL {
                durationMs = nil
            } else {
                durationMs = statement.columnDouble(at: 5)
            }

            let peakMemoryBytes: UInt64?
            if statement.columnType(at: 6) == SQLITE_NULL {
                peakMemoryBytes = nil
            } else {
                let value = statement.columnInt64(at: 6)
                guard value >= 0 else {
                    throw SQLiteStoreError.invalidData("workspace_project_output_cache has negative peak memory value.")
                }
                peakMemoryBytes = UInt64(value)
            }

            outputByProjectID[normalizedProjectID] = ProjectOutputCacheEntry(
                command: command,
                stdout: stdout,
                stderr: stderr,
                exitCode: statement.columnInt(at: 4),
                durationMs: durationMs,
                peakMemoryBytes: peakMemoryBytes,
                wasStopped: statement.columnInt(at: 7) == 1,
                resultMessage: resultMessage
            )
        }

        return outputByProjectID
    }

    func sync(_ outputByProjectID: [String: ProjectOutputCacheEntry]) throws {
        let sanitized = outputByProjectID.reduce(into: [String: ProjectOutputCacheEntry]()) { result, item in
            let normalizedProjectID = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProjectID.isEmpty else { return }
            result[normalizedProjectID] = item.value
        }

        let newIDs = Set(sanitized.keys)
        let existingIDs = try fetchExistingProjectIDs()

        for (projectID, output) in sanitized {
            try upsert(projectID: projectID, output: output)
        }

        for existingID in existingIDs where !newIDs.contains(existingID) {
            let deleteStatement = try database.prepare("DELETE FROM workspace_project_output_cache WHERE project_id = ?;")
            try deleteStatement.bindText(existingID, at: 1)
            _ = try deleteStatement.step()
        }
    }

    private func fetchExistingProjectIDs() throws -> Set<String> {
        let statement = try database.prepare("SELECT project_id FROM workspace_project_output_cache;")
        var ids = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0)
            else {
                throw SQLiteStoreError.invalidData("workspace_project_output_cache contains invalid id rows.")
            }
            ids.insert(id)
        }

        return ids
    }

    private func upsert(projectID: String, output: ProjectOutputCacheEntry) throws {
        let statement = try database.prepare(
            """
            INSERT INTO workspace_project_output_cache (
                project_id,
                command,
                stdout,
                stderr,
                exit_code,
                duration_ms,
                peak_memory_bytes,
                was_stopped,
                result_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET
                command = excluded.command,
                stdout = excluded.stdout,
                stderr = excluded.stderr,
                exit_code = excluded.exit_code,
                duration_ms = excluded.duration_ms,
                peak_memory_bytes = excluded.peak_memory_bytes,
                was_stopped = excluded.was_stopped,
                result_message = excluded.result_message;
            """
        )

        try statement.bindText(projectID, at: 1)
        try statement.bindText(output.command, at: 2)
        try statement.bindText(output.stdout, at: 3)
        try statement.bindText(output.stderr, at: 4)
        try statement.bindInt(output.exitCode, at: 5)

        if let durationMs = output.durationMs {
            try statement.bindDouble(durationMs, at: 6)
        } else {
            try statement.bindNull(at: 6)
        }

        if let peakMemoryBytes = output.peakMemoryBytes {
            guard let value = Int64(exactly: peakMemoryBytes) else {
                throw SQLiteStoreError.invalidData("Peak memory value exceeds Int64 range.")
            }
            try statement.bindInt64(value, at: 7)
        } else {
            try statement.bindNull(at: 7)
        }

        try statement.bindInt(output.wasStopped ? 1 : 0, at: 8)
        try statement.bindText(output.resultMessage, at: 9)
        _ = try statement.step()
    }
}
