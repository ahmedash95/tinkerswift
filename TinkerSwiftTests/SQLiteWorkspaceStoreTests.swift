import Foundation
import SQLite3
import XCTest
@testable import TinkerSwift

@MainActor
final class SQLiteWorkspaceStoreTests: XCTestCase {
    func testMigratesLegacySnapshotOnlyOnce() {
        let databaseURL = makeDatabaseURL()
        let fallbackStore = StubWorkspacePersistenceStore(snapshot: sampleSnapshot())
        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)

        let firstLoad = store.load()
        assertSnapshot(firstLoad, matches: fallbackStore.snapshot)
        XCTAssertEqual(fallbackStore.loadCallCount, 1)

        // Loading again should use SQLite data and skip legacy fallback.
        let secondLoad = store.load()
        assertSnapshot(secondLoad, matches: fallbackStore.snapshot)
        XCTAssertEqual(fallbackStore.loadCallCount, 1)
    }

    func testPersistsAndLoadsRoundTrip() {
        let databaseURL = makeDatabaseURL()
        let fallbackStore = StubWorkspacePersistenceStore(snapshot: emptySnapshot())
        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)

        _ = store.load()

        let settings = customSettings()
        let project = WorkspaceProject.local(path: "/tmp/roundtrip-laravel")
        let runHistoryItem = ProjectRunHistoryItem(
            id: "history-1",
            projectID: project.id,
            code: "return 42;",
            executedAt: Date(timeIntervalSince1970: 1_704_000_000.321)
        )
        let output = ProjectOutputCacheEntry(
            command: "php artisan tinker",
            stdout: "42",
            stderr: "",
            exitCode: 0,
            durationMs: 120.5,
            peakMemoryBytes: 8_388_608,
            wasStopped: false,
            resultMessage: "Execution completed."
        )

        store.save(settings: settings)
        store.save(projects: [project])
        store.save(runHistory: [runHistoryItem])
        store.save(projectDraftsByProjectID: [project.id: "return User::count();"])
        store.save(projectOutputCacheByProjectID: [project.id: output])
        let snippet = WorkspaceSnippetItem(
            id: "snippet-1",
            title: "Count users",
            content: "return User::count();",
            sourceProjectID: project.id,
            createdAt: Date(timeIntervalSince1970: 1_704_000_111.0),
            updatedAt: Date(timeIntervalSince1970: 1_704_000_111.0)
        )
        store.save(snippets: [snippet])
        store.save(selectedProjectID: project.id)

        let loaded = store.load()

        assertSettings(loaded.settings, equals: settings)
        XCTAssertEqual(loaded.selectedProjectID, project.id)
        XCTAssertEqual(loaded.projects, [project])
        XCTAssertEqual(loaded.runHistory, [runHistoryItem])
        XCTAssertEqual(loaded.projectDraftsByProjectID[project.id], "return User::count();")
        assertOutput(loaded.projectOutputCacheByProjectID[project.id], equals: output)
        XCTAssertEqual(loaded.snippets, [snippet])
        XCTAssertNil(loaded.startupRecoveryMessage)
    }

    func testRecoversFromCorruptedDatabaseFile() throws {
        let databaseURL = makeDatabaseURL()
        let fallbackStore = StubWorkspacePersistenceStore(snapshot: emptySnapshot())

        try Data("not a sqlite file".utf8).write(to: databaseURL, options: .atomic)

        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)
        let loaded = store.load()

        XCTAssertEqual(loaded.projects, [])
        XCTAssertNotNil(loaded.startupRecoveryMessage)
        XCTAssertTrue(loaded.startupRecoveryMessage?.contains("Failed to read saved application data") == true)

        let project = WorkspaceProject.local(path: "/tmp/recovered-db")
        store.save(projects: [project])
        let reloaded = store.load()

        XCTAssertEqual(reloaded.projects, [project])
        XCTAssertEqual(reloaded.snippets, [])
    }

    func testProjectsSyncPrunesRemovedProjects() {
        let databaseURL = makeDatabaseURL()
        let fallbackStore = StubWorkspacePersistenceStore(snapshot: emptySnapshot())
        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)
        _ = store.load()

        let projectA = WorkspaceProject.local(path: "/tmp/project-a")
        let projectB = WorkspaceProject.local(path: "/tmp/project-b")

        store.save(projects: [projectA, projectB])
        store.save(projects: [projectB])

        let loaded = store.load()
        XCTAssertEqual(Set(loaded.projects.map(\.id)), Set([projectB.id]))
    }

    func testExistingSQLiteDataSkipsLegacyOverwrite() {
        let databaseURL = makeDatabaseURL()
        let bootstrapFallback = StubWorkspacePersistenceStore(snapshot: emptySnapshot())
        let firstStore = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: bootstrapFallback)
        _ = firstStore.load()

        let existingProject = WorkspaceProject.local(path: "/tmp/existing-sqlite-project")
        firstStore.save(projects: [existingProject])

        let legacyFallback = StubWorkspacePersistenceStore(snapshot: sampleSnapshot())
        let secondStore = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: legacyFallback)
        let loaded = secondStore.load()

        XCTAssertEqual(legacyFallback.loadCallCount, 0)
        XCTAssertEqual(Set(loaded.projects.map(\.id)), Set([existingProject.id]))
    }

    func testSnippetsSyncPrunesRemovedItems() {
        let databaseURL = makeDatabaseURL()
        let fallbackStore = StubWorkspacePersistenceStore(snapshot: emptySnapshot())
        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)
        _ = store.load()

        let project = WorkspaceProject.local(path: "/tmp/snippets-prune")
        let snippetA = WorkspaceSnippetItem(
            id: "snippet-a",
            title: "Snippet A",
            content: "return 'A';",
            sourceProjectID: project.id,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let snippetB = WorkspaceSnippetItem(
            id: "snippet-b",
            title: "Snippet B",
            content: "return 'B';",
            sourceProjectID: project.id,
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        store.save(snippets: [snippetA, snippetB])
        store.save(snippets: [snippetB])

        let loaded = store.load()
        XCTAssertEqual(loaded.snippets, [snippetB])
    }

    func testIgnoresFallbackSnippetsDuringInitialImport() {
        let databaseURL = makeDatabaseURL()
        var snapshot = sampleSnapshot()
        snapshot.snippets = [
            WorkspaceSnippetItem(
                id: "legacy-snippet",
                title: "Legacy",
                content: "return 'legacy';",
                sourceProjectID: snapshot.projects.first?.id ?? "local:/tmp/project",
                createdAt: Date(timeIntervalSince1970: 123),
                updatedAt: Date(timeIntervalSince1970: 123)
            )
        ]
        let fallbackStore = StubWorkspacePersistenceStore(snapshot: snapshot)
        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)

        let loaded = store.load()

        XCTAssertEqual(fallbackStore.loadCallCount, 1)
        XCTAssertEqual(loaded.projects, fallbackStore.snapshot.projects)
        XCTAssertEqual(loaded.runHistory, fallbackStore.snapshot.runHistory)
        XCTAssertEqual(loaded.snippets, [])
    }

    func testMigratesExistingVersion1DatabaseToVersion2Schema() throws {
        let databaseURL = makeDatabaseURL()
        try seedVersion1Database(at: databaseURL)

        let fallbackStore = StubWorkspacePersistenceStore(snapshot: emptySnapshot())
        let store = SQLiteWorkspaceStore(databaseURL: databaseURL, fallbackStore: fallbackStore)
        _ = store.load()

        let database = try SQLiteDatabase(databaseURL: databaseURL)
        defer { database.close() }
        XCTAssertTrue(try database.tableExists("workspace_snippets"))

        let statement = try database.prepare("SELECT COALESCE(MAX(version), 0) FROM workspace_schema_migrations;")
        XCTAssertEqual(try statement.step(), SQLITE_ROW)
        XCTAssertEqual(statement.columnInt(at: 0), 2)
    }

    private func makeDatabaseURL() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tinkerswift-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("workspace.sqlite", isDirectory: false)
    }

    private func sampleSnapshot() -> WorkspacePersistenceSnapshot {
        let project = WorkspaceProject.local(path: "/tmp/sample-laravel")
        let runHistoryItem = ProjectRunHistoryItem(
            id: "sample-history-1",
            projectID: project.id,
            code: "return now()->toIso8601String();",
            executedAt: Date(timeIntervalSince1970: 1_703_000_000.123)
        )
        let output = ProjectOutputCacheEntry(
            command: "php artisan tinker",
            stdout: "\"2025-01-01T00:00:00+00:00\"",
            stderr: "",
            exitCode: 0,
            durationMs: 95.0,
            peakMemoryBytes: 4_194_304,
            wasStopped: false,
            resultMessage: "Execution completed."
        )

        return WorkspacePersistenceSnapshot(
            settings: customSettings(),
            selectedProjectID: project.id,
            projects: [project],
            runHistory: [runHistoryItem],
            projectDraftsByProjectID: [project.id: "return now();"],
            projectOutputCacheByProjectID: [project.id: output],
            snippets: [],
            startupRecoveryMessage: nil
        )
    }

    private func emptySnapshot() -> WorkspacePersistenceSnapshot {
        WorkspacePersistenceSnapshot(
            settings: AppSettings(
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
            ),
            selectedProjectID: "",
            projects: [],
            runHistory: [],
            projectDraftsByProjectID: [:],
            projectOutputCacheByProjectID: [:],
            snippets: [],
            startupRecoveryMessage: nil
        )
    }

    private func customSettings() -> AppSettings {
        AppSettings(
            appTheme: .dark,
            appUIScale: 1.2,
            hasCompletedOnboarding: true,
            showLineNumbers: false,
            wrapLines: false,
            highlightSelectedLine: false,
            syntaxHighlighting: true,
            lspCompletionEnabled: true,
            lspAutoTriggerEnabled: false,
            autoFormatOnRunEnabled: false,
            lspServerPathOverride: "/usr/local/bin/phpactor",
            phpBinaryPathOverride: "/usr/local/bin/php",
            dockerBinaryPathOverride: "/usr/local/bin/docker",
            laravelBinaryPathOverride: "/usr/local/bin/laravel"
        )
    }

    private func assertSnapshot(_ actual: WorkspacePersistenceSnapshot, matches expected: WorkspacePersistenceSnapshot) {
        assertSettings(actual.settings, equals: expected.settings)
        XCTAssertEqual(actual.selectedProjectID, expected.selectedProjectID)
        XCTAssertEqual(actual.projects, expected.projects)
        XCTAssertEqual(actual.runHistory, expected.runHistory)
        XCTAssertEqual(actual.projectDraftsByProjectID, expected.projectDraftsByProjectID)
        XCTAssertEqual(actual.projectOutputCacheByProjectID.keys.sorted(), expected.projectOutputCacheByProjectID.keys.sorted())
        XCTAssertEqual(actual.snippets, expected.snippets)

        for (projectID, expectedOutput) in expected.projectOutputCacheByProjectID {
            assertOutput(actual.projectOutputCacheByProjectID[projectID], equals: expectedOutput)
        }
    }

    private func assertSettings(_ actual: AppSettings, equals expected: AppSettings) {
        XCTAssertEqual(actual.appTheme, expected.appTheme)
        XCTAssertEqual(actual.appUIScale, expected.appUIScale, accuracy: 0.000_1)
        XCTAssertEqual(actual.hasCompletedOnboarding, expected.hasCompletedOnboarding)
        XCTAssertEqual(actual.showLineNumbers, expected.showLineNumbers)
        XCTAssertEqual(actual.wrapLines, expected.wrapLines)
        XCTAssertEqual(actual.highlightSelectedLine, expected.highlightSelectedLine)
        XCTAssertEqual(actual.syntaxHighlighting, expected.syntaxHighlighting)
        XCTAssertEqual(actual.lspCompletionEnabled, expected.lspCompletionEnabled)
        XCTAssertEqual(actual.lspAutoTriggerEnabled, expected.lspAutoTriggerEnabled)
        XCTAssertEqual(actual.autoFormatOnRunEnabled, expected.autoFormatOnRunEnabled)
        XCTAssertEqual(actual.lspServerPathOverride, expected.lspServerPathOverride)
        XCTAssertEqual(actual.phpBinaryPathOverride, expected.phpBinaryPathOverride)
        XCTAssertEqual(actual.dockerBinaryPathOverride, expected.dockerBinaryPathOverride)
        XCTAssertEqual(actual.laravelBinaryPathOverride, expected.laravelBinaryPathOverride)
    }

    private func assertOutput(_ actual: ProjectOutputCacheEntry?, equals expected: ProjectOutputCacheEntry) {
        guard let actual else {
            XCTFail("Expected cached output to be present")
            return
        }

        XCTAssertEqual(actual.command, expected.command)
        XCTAssertEqual(actual.stdout, expected.stdout)
        XCTAssertEqual(actual.stderr, expected.stderr)
        XCTAssertEqual(actual.exitCode, expected.exitCode)
        switch (actual.durationMs, expected.durationMs) {
        case (nil, nil):
            break
        case let (lhs?, rhs?):
            XCTAssertEqual(lhs, rhs, accuracy: 0.000_1)
        default:
            XCTFail("Duration mismatch")
        }
        XCTAssertEqual(actual.peakMemoryBytes, expected.peakMemoryBytes)
        XCTAssertEqual(actual.wasStopped, expected.wasStopped)
        XCTAssertEqual(actual.resultMessage, expected.resultMessage)
    }

    private func seedVersion1Database(at databaseURL: URL) throws {
        let database = try SQLiteDatabase(databaseURL: databaseURL)
        defer { database.close() }

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_schema_migrations (
                version INTEGER PRIMARY KEY NOT NULL,
                applied_at TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_projects (
                id TEXT PRIMARY KEY NOT NULL,
                payload_json TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_run_history (
                id TEXT PRIMARY KEY NOT NULL,
                project_id TEXT NOT NULL,
                code TEXT NOT NULL,
                executed_at TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_project_drafts (
                project_id TEXT PRIMARY KEY NOT NULL,
                code TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS workspace_project_output_cache (
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
        try database.execute(
            """
            INSERT OR REPLACE INTO workspace_schema_migrations (version, applied_at)
            VALUES (1, '2025-01-01T00:00:00Z');
            """
        )
    }
}

@MainActor
private final class StubWorkspacePersistenceStore: WorkspacePersistenceStore {
    var snapshot: WorkspacePersistenceSnapshot
    private(set) var loadCallCount = 0

    init(snapshot: WorkspacePersistenceSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> WorkspacePersistenceSnapshot {
        loadCallCount += 1
        return snapshot
    }

    func save(settings: AppSettings) {}

    func save(projects: [WorkspaceProject]) {}

    func save(runHistory: [ProjectRunHistoryItem]) {}

    func save(projectDraftsByProjectID: [String: String]) {}

    func save(projectOutputCacheByProjectID: [String: ProjectOutputCacheEntry]) {}

    func save(snippets: [WorkspaceSnippetItem]) {}

    func save(selectedProjectID: String) {}
}
