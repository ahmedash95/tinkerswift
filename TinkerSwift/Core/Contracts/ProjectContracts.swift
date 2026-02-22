import Foundation

enum ProjectConnectionKind: String, Codable, Sendable {
    case local
    case docker
    case ssh

    var projectSymbolName: String {
        switch self {
        case .local:
            return "folder"
        case .docker:
            return "shippingbox.fill"
        case .ssh:
            return "network"
        }
    }
}

struct DockerProjectConfig: Codable, Hashable, Sendable {
    var containerID: String
    var containerName: String
    var projectPath: String
}

enum SSHAuthenticationMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case privateKey
    case password

    var displayName: String {
        switch self {
        case .privateKey:
            return "Private Key"
        case .password:
            return "Password"
        }
    }
}

struct SSHProjectConfig: Hashable, Sendable {
    var host: String
    var port: Int
    var username: String
    var projectPath: String
    var authenticationMethod: SSHAuthenticationMethod
    var privateKeyPath: String
    var password: String

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case username
        case projectPath
        case authenticationMethod
        case privateKeyPath
    }
}

extension SSHProjectConfig: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = min(max(try container.decodeIfPresent(Int.self, forKey: .port) ?? 22, 1), 65535)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? "/"
        authenticationMethod = try container.decodeIfPresent(SSHAuthenticationMethod.self, forKey: .authenticationMethod) ?? .privateKey
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        password = ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(projectPath, forKey: .projectPath)
        try container.encode(authenticationMethod, forKey: .authenticationMethod)
        try container.encode(privateKeyPath, forKey: .privateKeyPath)
    }
}

enum ProjectConnection: Codable, Hashable, Sendable {
    case local(path: String)
    case docker(DockerProjectConfig)
    case ssh(SSHProjectConfig)

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case docker
        case ssh
    }

    var kind: ProjectConnectionKind {
        switch self {
        case .local:
            return .local
        case .docker:
            return .docker
        case .ssh:
            return .ssh
        }
    }

    var projectPath: String {
        switch self {
        case let .local(path):
            return path
        case let .docker(config):
            return config.projectPath
        case let .ssh(config):
            return config.projectPath
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ProjectConnectionKind.self, forKey: .kind)
        switch kind {
        case .local:
            let path = try container.decode(String.self, forKey: .path)
            self = .local(path: path)
        case .docker:
            let config = try container.decode(DockerProjectConfig.self, forKey: .docker)
            self = .docker(config)
        case .ssh:
            let config = try container.decode(SSHProjectConfig.self, forKey: .ssh)
            self = .ssh(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .local(path):
            try container.encode(ProjectConnectionKind.local, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .docker(config):
            try container.encode(ProjectConnectionKind.docker, forKey: .kind)
            try container.encode(config, forKey: .docker)
        case let .ssh(config):
            try container.encode(ProjectConnectionKind.ssh, forKey: .kind)
            try container.encode(config, forKey: .ssh)
        }
    }
}

struct WorkspaceProject: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var languageID: String
    var connection: ProjectConnection

    var path: String { connection.projectPath }

    var subtitle: String {
        switch connection {
        case let .local(path):
            return path
        case let .docker(config):
            return "\(config.containerName):\(config.projectPath)"
        case let .ssh(config):
            return "\(config.username)@\(config.host):\(config.port):\(config.projectPath)"
        }
    }

    var isLocal: Bool {
        if case .local = connection { return true }
        return false
    }

    static func local(path: String, languageID: String = "php") -> WorkspaceProject {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return WorkspaceProject(
            id: "local:\(normalized)",
            name: URL(fileURLWithPath: normalized).lastPathComponent,
            languageID: languageID,
            connection: .local(path: normalized)
        )
    }

    static func docker(
        containerID: String,
        containerName: String,
        projectPath: String,
        languageID: String = "php"
    ) -> WorkspaceProject {
        let normalizedPath = WorkspaceProject.normalizePOSIXPath(projectPath)
        let displayPath = URL(fileURLWithPath: normalizedPath).lastPathComponent
        return WorkspaceProject(
            id: "docker:\(containerID):\(normalizedPath)",
            name: "\(containerName) · \(displayPath)",
            languageID: languageID,
            connection: .docker(
                DockerProjectConfig(
                    containerID: containerID,
                    containerName: containerName,
                    projectPath: normalizedPath
                )
            )
        )
    }

    static func ssh(
        host: String,
        port: Int = 22,
        username: String,
        projectPath: String,
        authenticationMethod: SSHAuthenticationMethod = .privateKey,
        privateKeyPath: String = "",
        password: String = "",
        languageID: String = "php"
    ) -> WorkspaceProject {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = min(max(port, 1), 65535)
        let normalizedPath = WorkspaceProject.normalizePOSIXPath(projectPath)
        let normalizedPrivateKeyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = URL(fileURLWithPath: normalizedPath).lastPathComponent
        let displayPath = tail.isEmpty ? normalizedPath : tail
        return WorkspaceProject(
            id: "ssh:\(normalizedUsername)@\(normalizedHost):\(normalizedPort):\(normalizedPath)",
            name: "\(normalizedUsername)@\(normalizedHost) · \(displayPath)",
            languageID: languageID,
            connection: .ssh(
                SSHProjectConfig(
                    host: normalizedHost,
                    port: normalizedPort,
                    username: normalizedUsername,
                    projectPath: normalizedPath,
                    authenticationMethod: authenticationMethod,
                    privateKeyPath: normalizedPrivateKeyPath,
                    password: password
                )
            )
        )
    }

    private static func normalizePOSIXPath(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "/"
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

typealias LaravelProject = WorkspaceProject

struct DockerContainerSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let image: String
    let status: String
}
