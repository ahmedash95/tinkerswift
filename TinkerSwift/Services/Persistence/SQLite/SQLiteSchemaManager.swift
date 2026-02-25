import Foundation
import SQLite3

final class SQLiteSchemaManager {
    private enum Table {
        static let migrations = "workspace_schema_migrations"
        static let settings = "workspace_settings"
        static let meta = "workspace_meta"
        static let projects = "workspace_projects"
        static let runHistory = "workspace_run_history"
        static let drafts = "workspace_project_drafts"
        static let outputCache = "workspace_project_output_cache"

        static let legacySettings = "settings"
        static let legacyProjects = "projects"
        static let legacyRunHistory = "run_history"
        static let legacyDrafts = "project_drafts"
        static let legacyOutputCache = "project_output_cache"
    }

    private let database: SQLiteDatabase
    private let currentVersion = 1

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func migrateIfNeeded() throws {
        try createMigrationsTableIfNeeded()

        let appliedVersion = try latestAppliedVersion()
        if appliedVersion == 0, try hasLegacySchemaWithoutVersioning() {
            try migrateLegacySchemaToCurrent()
            try recordMigrationVersion(currentVersion)
            return
        }

        if appliedVersion < currentVersion {
            try createCurrentSchemaIfNeeded()
            try recordMigrationVersion(currentVersion)
        }
    }

    private func createMigrationsTableIfNeeded() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.migrations) (
                version INTEGER PRIMARY KEY NOT NULL,
                applied_at TEXT NOT NULL
            );
            """
        )
    }

    private func latestAppliedVersion() throws -> Int {
        let statement = try database.prepare("SELECT COALESCE(MAX(version), 0) FROM \(Table.migrations);")
        guard try statement.step() == SQLITE_ROW else {
            return 0
        }
        return Int(statement.columnInt(at: 0))
    }

    private func recordMigrationVersion(_ version: Int) throws {
        let statement = try database.prepare(
            """
            INSERT OR IGNORE INTO \(Table.migrations) (version, applied_at)
            VALUES (?, ?);
            """
        )
        try statement.bindInt64(Int64(version), at: 1)
        try statement.bindText(ISO8601DateFormatter().string(from: Date()), at: 2)
        _ = try statement.step()
    }

    private func hasLegacySchemaWithoutVersioning() throws -> Bool {
        let hasLegacyTable =
            try database.tableExists(Table.legacySettings) ||
            (try database.tableExists(Table.legacyProjects)) ||
            (try database.tableExists(Table.legacyRunHistory)) ||
            (try database.tableExists(Table.legacyDrafts)) ||
            (try database.tableExists(Table.legacyOutputCache))

        let hasCurrentProjects = try database.tableExists(Table.projects)
        return hasLegacyTable && !hasCurrentProjects
    }

    private func migrateLegacySchemaToCurrent() throws {
        try createCurrentSchemaIfNeeded()

        try database.inTransaction {
            if try database.tableExists(Table.legacySettings) {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(Table.settings) (key, value)
                    SELECT key, value FROM \(Table.legacySettings);
                    """
                )
                try database.execute("DROP TABLE IF EXISTS \(Table.legacySettings);")
            }

            if try database.tableExists(Table.legacyProjects) {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(Table.projects) (id, payload_json)
                    SELECT id, payload_json FROM \(Table.legacyProjects);
                    """
                )
                try database.execute("DROP TABLE IF EXISTS \(Table.legacyProjects);")
            }

            if try database.tableExists(Table.legacyRunHistory) {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(Table.runHistory) (id, project_id, code, executed_at)
                    SELECT id, project_id, code, executed_at FROM \(Table.legacyRunHistory);
                    """
                )
                try database.execute("DROP TABLE IF EXISTS \(Table.legacyRunHistory);")
            }

            if try database.tableExists(Table.legacyDrafts) {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(Table.drafts) (project_id, code)
                    SELECT project_id, code FROM \(Table.legacyDrafts);
                    """
                )
                try database.execute("DROP TABLE IF EXISTS \(Table.legacyDrafts);")
            }

            if try database.tableExists(Table.legacyOutputCache) {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO \(Table.outputCache) (
                        project_id,
                        command,
                        stdout,
                        stderr,
                        exit_code,
                        duration_ms,
                        peak_memory_bytes,
                        was_stopped,
                        result_message
                    )
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
                    FROM \(Table.legacyOutputCache);
                    """
                )
                try database.execute("DROP TABLE IF EXISTS \(Table.legacyOutputCache);")
            }
        }
    }

    private func createCurrentSchemaIfNeeded() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.settings) (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.meta) (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.projects) (
                id TEXT PRIMARY KEY NOT NULL,
                payload_json TEXT NOT NULL
            );
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.runHistory) (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                code TEXT NOT NULL,
                executed_at TEXT NOT NULL
            );
            """
        )

        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS workspace_run_history_project_executed_idx
            ON \(Table.runHistory) (project_id, executed_at DESC);
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.drafts) (
                project_id TEXT PRIMARY KEY NOT NULL,
                code TEXT NOT NULL
            );
            """
        )

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS \(Table.outputCache) (
                project_id TEXT PRIMARY KEY NOT NULL,
                command TEXT NOT NULL,
                stdout TEXT NOT NULL,
                stderr TEXT NOT NULL,
                exit_code INTEGER NOT NULL,
                duration_ms REAL,
                peak_memory_bytes INTEGER,
                was_stopped INTEGER NOT NULL,
                result_message TEXT NOT NULL
            );
            """
        )
    }
}
