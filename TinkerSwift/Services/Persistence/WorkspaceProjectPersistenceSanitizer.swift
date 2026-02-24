import Foundation

struct WorkspaceProjectPersistenceSanitizer {
    func sanitize(_ project: WorkspaceProject) -> WorkspaceProject? {
        switch project.connection {
        case let .local(path):
            let normalizedPath = normalizeLocalPath(path)
            guard !normalizedPath.isEmpty else { return nil }
            let normalized = WorkspaceProject.local(path: normalizedPath, languageID: project.languageID)
            if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized
            }
            return WorkspaceProject(
                id: normalized.id,
                name: project.name,
                languageID: project.languageID,
                connection: normalized.connection
            )

        case let .docker(config):
            let containerID = config.containerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let containerName = config.containerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = normalizePOSIXPath(config.projectPath)
            guard !containerID.isEmpty, !containerName.isEmpty, !projectPath.isEmpty else {
                return nil
            }
            let normalized = WorkspaceProject.docker(
                containerID: containerID,
                containerName: containerName,
                projectPath: projectPath,
                languageID: project.languageID
            )
            if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized
            }
            return WorkspaceProject(
                id: normalized.id,
                name: project.name,
                languageID: project.languageID,
                connection: normalized.connection
            )

        case let .ssh(config):
            var host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
            var username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if username.isEmpty, host.contains("@") {
                let parts = host.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 {
                    username = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    host = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            let port = min(max(config.port, 1), 65535)
            let projectPath = normalizePOSIXPath(config.projectPath)
            let privateKeyPath = config.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !host.isEmpty, !username.isEmpty, !projectPath.isEmpty else { return nil }
            guard !host.contains(where: \.isWhitespace), !username.contains(where: \.isWhitespace) else {
                return nil
            }

            let normalized = WorkspaceProject.ssh(
                host: host,
                port: port,
                username: username,
                projectPath: projectPath,
                authenticationMethod: config.authenticationMethod,
                privateKeyPath: privateKeyPath,
                password: config.password,
                languageID: project.languageID
            )
            if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized
            }
            return WorkspaceProject(
                id: normalized.id,
                name: project.name,
                languageID: project.languageID,
                connection: normalized.connection
            )
        }
    }

    func sanitizeDeduplicated(_ projects: [WorkspaceProject]) -> [WorkspaceProject] {
        var seenIDs = Set<String>()
        var sanitized: [WorkspaceProject] = []

        for project in projects {
            guard let normalized = sanitize(project) else { continue }
            guard seenIDs.insert(normalized.id).inserted else { continue }
            sanitized.append(normalized)
        }

        return sanitized
    }

    func normalizeLocalPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        var normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        if normalized == "/" {
            return ""
        }

        return normalized
    }

    func normalizePOSIXPath(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return ""
        }
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
