import Foundation
import SQLite3

final class SQLiteSnippetsRepository {
    private let database: SQLiteDatabase
    private let formatterWithFractional: ISO8601DateFormatter
    private let formatter: ISO8601DateFormatter

    init(database: SQLiteDatabase) {
        self.database = database

        formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
    }

    func load() throws -> [WorkspaceSnippetItem] {
        let statement = try database.prepare(
            """
            SELECT id, title, content, source_project_id, created_at, updated_at
            FROM workspace_snippets
            ORDER BY created_at DESC;
            """
        )

        var snippets: [WorkspaceSnippetItem] = []
        var seen = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0),
                  let title = statement.columnText(at: 1),
                  let content = statement.columnText(at: 2),
                  let sourceProjectID = statement.columnText(at: 3),
                  let createdAtRaw = statement.columnText(at: 4),
                  let updatedAtRaw = statement.columnText(at: 5),
                  let createdAt = parseDate(createdAtRaw),
                  let updatedAt = parseDate(updatedAtRaw)
            else {
                throw SQLiteStoreError.invalidData("workspace_snippets contains invalid rows.")
            }

            let normalizedTitle = normalizeTitle(title)
            let normalizedContent = normalizeContent(content)
            let normalizedProjectID = sourceProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !normalizedTitle.isEmpty, !normalizedContent.isEmpty, !normalizedProjectID.isEmpty else {
                continue
            }
            guard seen.insert(id).inserted else { continue }

            snippets.append(
                WorkspaceSnippetItem(
                    id: id,
                    title: normalizedTitle,
                    content: normalizedContent,
                    sourceProjectID: normalizedProjectID,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return snippets
    }

    func sync(_ snippets: [WorkspaceSnippetItem]) throws {
        let sanitized = sanitize(snippets)
        let newIDs = Set(sanitized.map(\.id))
        let existingIDs = try fetchExistingIDs()

        for snippet in sanitized {
            try upsert(snippet)
        }

        for existingID in existingIDs where !newIDs.contains(existingID) {
            let deleteStatement = try database.prepare("DELETE FROM workspace_snippets WHERE id = ?;")
            try deleteStatement.bindText(existingID, at: 1)
            _ = try deleteStatement.step()
        }
    }

    private func fetchExistingIDs() throws -> Set<String> {
        let statement = try database.prepare("SELECT id FROM workspace_snippets;")
        var ids = Set<String>()

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let id = statement.columnText(at: 0)
            else {
                throw SQLiteStoreError.invalidData("workspace_snippets contains invalid id rows.")
            }
            ids.insert(id)
        }

        return ids
    }

    private func upsert(_ snippet: WorkspaceSnippetItem) throws {
        let statement = try database.prepare(
            """
            INSERT INTO workspace_snippets (
                id,
                title,
                content,
                source_project_id,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                content = excluded.content,
                source_project_id = excluded.source_project_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """
        )
        try statement.bindText(snippet.id, at: 1)
        try statement.bindText(snippet.title, at: 2)
        try statement.bindText(snippet.content, at: 3)
        try statement.bindText(snippet.sourceProjectID, at: 4)
        try statement.bindText(formatterWithFractional.string(from: snippet.createdAt), at: 5)
        try statement.bindText(formatterWithFractional.string(from: snippet.updatedAt), at: 6)
        _ = try statement.step()
    }

    private func sanitize(_ snippets: [WorkspaceSnippetItem]) -> [WorkspaceSnippetItem] {
        var seen = Set<String>()
        var sanitized: [WorkspaceSnippetItem] = []

        for snippet in snippets {
            let normalizedID = snippet.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = normalizeTitle(snippet.title)
            let normalizedContent = normalizeContent(snippet.content)
            let normalizedProjectID = snippet.sourceProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty,
                  !normalizedTitle.isEmpty,
                  !normalizedContent.isEmpty,
                  !normalizedProjectID.isEmpty
            else {
                continue
            }
            guard seen.insert(normalizedID).inserted else { continue }

            sanitized.append(
                WorkspaceSnippetItem(
                    id: normalizedID,
                    title: normalizedTitle,
                    content: normalizedContent,
                    sourceProjectID: normalizedProjectID,
                    createdAt: snippet.createdAt,
                    updatedAt: snippet.updatedAt
                )
            )
        }

        return sanitized
    }

    private func parseDate(_ raw: String) -> Date? {
        if let value = formatterWithFractional.date(from: raw) {
            return value
        }
        return formatter.date(from: raw)
    }

    private func normalizeTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 120 {
            return trimmed
        }
        return String(trimmed.prefix(120))
    }

    private func normalizeContent(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : normalized
    }
}
