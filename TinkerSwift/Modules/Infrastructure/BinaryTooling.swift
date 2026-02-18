import Foundation

enum AppBinaryTool: String, CaseIterable, Sendable, Identifiable {
    case phpactor
    case php
    case docker
    case laravel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .phpactor: return "Phpactor"
        case .php: return "PHP"
        case .docker: return "Docker"
        case .laravel: return "Laravel Installer"
        }
    }

    var overrideDefaultsKey: String {
        switch self {
        case .phpactor:
            return "editor.lspServerPathOverride"
        case .php:
            return "binary.php.overridePath"
        case .docker:
            return "binary.docker.overridePath"
        case .laravel:
            return "binary.laravel.overridePath"
        }
    }
}

enum BinaryPathResolver {
    private static let fallbackDirectories = [
        "\(NSHomeDirectory())/Library/Application Support/Herd/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.composer/vendor/bin",
        "\(NSHomeDirectory())/.config/composer/vendor/bin"
    ]

    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = candidatePathEntries().joined(separator: ":")
        environment["HOME"] = NSHomeDirectory()
        return environment
    }

    static func overridePath(for tool: AppBinaryTool, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: tool.overrideDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func detectedDefaultPath(for tool: AppBinaryTool) -> String? {
        resolveExecutable(named: tool.rawValue, from: candidatePathEntries())
    }

    static func effectivePath(for tool: AppBinaryTool, defaults: UserDefaults = .standard) -> String? {
        let override = overridePath(for: tool, defaults: defaults)
        if !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return detectedDefaultPath(for: tool)
    }

    private static func candidatePathEntries() -> [String] {
        var entries: [String] = []
        if let pathValue = ProcessInfo.processInfo.environment["PATH"] {
            entries += pathValue.split(separator: ":").map(String.init)
        }
        entries += fallbackDirectories

        var deduped: [String] = []
        var seen = Set<String>()
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            deduped.append(trimmed)
        }
        return deduped
    }

    private static func resolveExecutable(named binary: String, from directories: [String]) -> String? {
        let fileManager = FileManager.default
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(binary).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
