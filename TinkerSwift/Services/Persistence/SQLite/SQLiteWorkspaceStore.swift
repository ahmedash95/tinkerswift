import Foundation
import os.log

@MainActor
final class SQLiteWorkspaceStore: WorkspacePersistenceStore {
    private enum MetaKey {
        static let selectedProjectID = "selected_project_id"
        static let didMigrateFromUserDefaults = "did_migrate_from_userdefaults_v1"
    }

    private static let migrationDoneValue = "1"
    private static let startupRecoveryMessage = "Failed to read saved application data. Your workspace history, cached code, and output were reset. You need to start over."
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ahmed.tinkerswift", category: "SQLiteWorkspaceStore")

    private let fileManager: FileManager
    private let fallbackStore: any WorkspacePersistenceStore
    private let databaseURL: URL

    private var database: SQLiteDatabase?
    private var settingsRepository: SQLiteSettingsRepository?
    private var metaRepository: SQLiteMetaRepository?
    private var projectsRepository: SQLiteProjectsRepository?
    private var runHistoryRepository: SQLiteRunHistoryRepository?
    private var draftsRepository: SQLiteDraftsRepository?
    private var outputCacheRepository: SQLiteOutputCacheRepository?
    private var snippetsRepository: SQLiteSnippetsRepository?

    private var pendingStartupRecoveryMessage: String?

    init(
        databaseURL: URL? = nil,
        fallbackStore: any WorkspacePersistenceStore = UserDefaultsWorkspaceStore(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fallbackStore = fallbackStore
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL(fileManager: fileManager)

        do {
            try bootstrap()
        } catch {
            recoverAfterFailure(error)
        }
    }

    func load() -> WorkspacePersistenceSnapshot {
        do {
            try ensureReady()
            try importFromUserDefaultsIfNeeded()

            guard let settingsRepository,
                  let metaRepository,
                  let projectsRepository,
                  let runHistoryRepository,
                  let draftsRepository,
                  let outputCacheRepository,
                  let snippetsRepository
            else {
                throw SQLiteStoreError.invalidData("SQLite repositories are not initialized.")
            }

            let settings = try settingsRepository.load()
            let projects = try projectsRepository.load()
            let runHistory = try runHistoryRepository.load()
            let drafts = try draftsRepository.load()
            let outputCache = try outputCacheRepository.load()
            let snippets = try snippetsRepository.load()

            var selectedProjectID = try metaRepository.value(for: MetaKey.selectedProjectID) ?? ""
            if selectedProjectID.isEmpty {
                selectedProjectID = projects.first?.id ?? ""
            }

            return WorkspacePersistenceSnapshot(
                settings: settings,
                selectedProjectID: selectedProjectID,
                projects: projects,
                runHistory: runHistory,
                projectDraftsByProjectID: drafts,
                projectOutputCacheByProjectID: outputCache,
                snippets: snippets,
                startupRecoveryMessage: consumePendingStartupRecoveryMessage()
            )
        } catch {
            recoverAfterFailure(error)
            return WorkspacePersistenceSnapshot(
                settings: Self.defaultSettings,
                selectedProjectID: "",
                projects: [],
                runHistory: [],
                projectDraftsByProjectID: [:],
                projectOutputCacheByProjectID: [:],
                snippets: [],
                startupRecoveryMessage: consumePendingStartupRecoveryMessage()
            )
        }
    }

    func save(settings: AppSettings) {
        performWrite {
            guard let settingsRepository else {
                throw SQLiteStoreError.invalidData("Settings repository is not initialized.")
            }
            try settingsRepository.save(settings)
        }
    }

    func save(projects: [WorkspaceProject]) {
        performWrite {
            guard let projectsRepository else {
                throw SQLiteStoreError.invalidData("Projects repository is not initialized.")
            }
            try projectsRepository.sync(projects)
        }
    }

    func save(runHistory: [ProjectRunHistoryItem]) {
        performWrite {
            guard let runHistoryRepository else {
                throw SQLiteStoreError.invalidData("Run history repository is not initialized.")
            }
            try runHistoryRepository.sync(runHistory)
        }
    }

    func save(projectDraftsByProjectID: [String: String]) {
        performWrite {
            guard let draftsRepository else {
                throw SQLiteStoreError.invalidData("Drafts repository is not initialized.")
            }
            try draftsRepository.sync(projectDraftsByProjectID)
        }
    }

    func save(projectOutputCacheByProjectID: [String: ProjectOutputCacheEntry]) {
        performWrite {
            guard let outputCacheRepository else {
                throw SQLiteStoreError.invalidData("Output cache repository is not initialized.")
            }
            try outputCacheRepository.sync(projectOutputCacheByProjectID)
        }
    }

    func save(snippets: [WorkspaceSnippetItem]) {
        performWrite {
            guard let snippetsRepository else {
                throw SQLiteStoreError.invalidData("Snippets repository is not initialized.")
            }
            try snippetsRepository.sync(snippets)
        }
    }

    func save(selectedProjectID: String) {
        let normalizedProjectID = selectedProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        performWrite {
            guard let metaRepository else {
                throw SQLiteStoreError.invalidData("Meta repository is not initialized.")
            }
            try metaRepository.setValue(normalizedProjectID, for: MetaKey.selectedProjectID)
        }
    }

    private func performWrite(_ block: () throws -> Void) {
        do {
            try ensureReady()
            guard let database else {
                throw SQLiteStoreError.invalidData("Database is not available for write.")
            }
            try database.inTransaction {
                try block()
            }
        } catch {
            if isRecoveryEligible(error) {
                recoverAfterFailure(error)
            } else {
                Self.logger.error("SQLite write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ensureReady() throws {
        if database == nil {
            try bootstrap()
        }
    }

    private func bootstrap() throws {
        let db = try SQLiteDatabase(databaseURL: databaseURL, fileManager: fileManager)

        do {
            try configurePragmas(in: db)
            let schemaManager = SQLiteSchemaManager(database: db)
            try schemaManager.migrateIfNeeded()

            guard try db.quickCheck() else {
                throw SQLiteStoreError.invalidData("SQLite quick_check failed.")
            }

            database = db
            settingsRepository = SQLiteSettingsRepository(database: db)
            metaRepository = SQLiteMetaRepository(database: db)
            projectsRepository = SQLiteProjectsRepository(database: db)
            runHistoryRepository = SQLiteRunHistoryRepository(database: db)
            draftsRepository = SQLiteDraftsRepository(database: db)
            outputCacheRepository = SQLiteOutputCacheRepository(database: db)
            snippetsRepository = SQLiteSnippetsRepository(database: db)
        } catch {
            db.close()
            throw error
        }
    }

    private func configurePragmas(in database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL;")
        try database.execute("PRAGMA synchronous = NORMAL;")
        try database.execute("PRAGMA temp_store = MEMORY;")
    }

    private func importFromUserDefaultsIfNeeded() throws {
        guard let database,
              let settingsRepository,
              let metaRepository,
              let projectsRepository,
              let runHistoryRepository,
              let draftsRepository,
              let outputCacheRepository,
              let snippetsRepository
        else {
            throw SQLiteStoreError.invalidData("SQLite repositories are not initialized.")
        }

        if try metaRepository.value(for: MetaKey.didMigrateFromUserDefaults) == Self.migrationDoneValue {
            return
        }

        let hasExistingProjects = try !projectsRepository.load().isEmpty
        let hasExistingRunHistory = try !runHistoryRepository.load().isEmpty
        let hasExistingDrafts = try !draftsRepository.load().isEmpty
        let hasExistingOutputCache = try !outputCacheRepository.load().isEmpty
        let hasExistingSnippets = try !snippetsRepository.load().isEmpty
        let hasExistingData =
            hasExistingProjects ||
            hasExistingRunHistory ||
            hasExistingDrafts ||
            hasExistingOutputCache ||
            hasExistingSnippets

        if hasExistingData {
            try metaRepository.setValue(Self.migrationDoneValue, for: MetaKey.didMigrateFromUserDefaults)
            return
        }

        let snapshot = fallbackStore.load()

        try database.inTransaction {
            try settingsRepository.save(snapshot.settings)
            try projectsRepository.sync(snapshot.projects)
            try runHistoryRepository.sync(snapshot.runHistory)
            try draftsRepository.sync(snapshot.projectDraftsByProjectID)
            try outputCacheRepository.sync(snapshot.projectOutputCacheByProjectID)
            // Snippets are SQLite-only and are intentionally not imported from UserDefaults fallback.
            try metaRepository.setValue(snapshot.selectedProjectID, for: MetaKey.selectedProjectID)
            try metaRepository.setValue(Self.migrationDoneValue, for: MetaKey.didMigrateFromUserDefaults)
        }

        if let message = snapshot.startupRecoveryMessage {
            queueStartupRecoveryMessage(message)
        }
    }

    private func recoverAfterFailure(_ error: Error) {
        if !isRecoveryEligible(error) {
            return
        }

        closeCurrentDatabase()

        backupCorruptedDatabaseIfNeeded()
        removeSQLiteSidecarFiles()

        do {
            try bootstrap()
            queueStartupRecoveryMessage(Self.startupRecoveryMessage)
        } catch {
            closeCurrentDatabase()
            queueStartupRecoveryMessage(Self.startupRecoveryMessage)
        }
    }

    private func closeCurrentDatabase() {
        database?.close()
        database = nil
        settingsRepository = nil
        metaRepository = nil
        projectsRepository = nil
        runHistoryRepository = nil
        draftsRepository = nil
        outputCacheRepository = nil
        snippetsRepository = nil
    }

    private func backupCorruptedDatabaseIfNeeded() {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = databaseURL.deletingPathExtension()
            .appendingPathExtension("corrupt.\(timestamp).sqlite")

        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: databaseURL, to: backupURL)
        } catch {
            try? fileManager.removeItem(at: databaseURL)
        }
    }

    private func removeSQLiteSidecarFiles() {
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        if fileManager.fileExists(atPath: walURL.path) {
            try? fileManager.removeItem(at: walURL)
        }
        if fileManager.fileExists(atPath: shmURL.path) {
            try? fileManager.removeItem(at: shmURL)
        }
    }

    private func queueStartupRecoveryMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingStartupRecoveryMessage = trimmed
    }

    private func consumePendingStartupRecoveryMessage() -> String? {
        defer { pendingStartupRecoveryMessage = nil }
        return pendingStartupRecoveryMessage
    }

    private func isRecoveryEligible(_ error: Error) -> Bool {
        if let sqliteError = error as? SQLiteStoreError {
            return sqliteError.isCorruptionLike
        }
        return false
    }

    private static var defaultSettings: AppSettings {
        AppSettings(
            appTheme: .system,
            appUIScale: UIScaleSanitizer.defaultScale,
            hasCompletedOnboarding: false,
            showLineNumbers: true,
            wrapLines: true,
            highlightSelectedLine: true,
            syntaxHighlighting: true,
            lspCompletionEnabled: true,
            lspAutoTriggerEnabled: true,
            autoFormatOnRunEnabled: true,
            lspServerPathOverride: "",
            phpBinaryPathOverride: "",
            dockerBinaryPathOverride: "",
            laravelBinaryPathOverride: ""
        )
    }

    private static func defaultDatabaseURL(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ahmed.tinkerswift"
        return root
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("workspace.sqlite", isDirectory: false)
    }
}
