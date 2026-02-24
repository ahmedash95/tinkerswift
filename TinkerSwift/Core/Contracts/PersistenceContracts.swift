import AppKit
import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor
    func applyAppearance() {
        switch self {
        case .system:
            NSApp?.appearance = nil
        case .light:
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppSettings: Sendable {
    var appTheme: AppTheme
    var appUIScale: Double
    var hasCompletedOnboarding: Bool
    var showLineNumbers: Bool
    var wrapLines: Bool
    var highlightSelectedLine: Bool
    var syntaxHighlighting: Bool
    var lspCompletionEnabled: Bool
    var lspAutoTriggerEnabled: Bool
    var autoFormatOnRunEnabled: Bool
    var lspServerPathOverride: String
    var phpBinaryPathOverride: String
    var dockerBinaryPathOverride: String
    var laravelBinaryPathOverride: String
}

struct WorkspacePersistenceSnapshot: Sendable {
    var settings: AppSettings
    var selectedProjectID: String
    var projects: [WorkspaceProject]
    var runHistory: [ProjectRunHistoryItem]
    var projectDraftsByProjectID: [String: String]
    var projectOutputCacheByProjectID: [String: ProjectOutputCacheEntry]
    var startupRecoveryMessage: String?
}

struct ProjectOutputCacheEntry: Codable, Sendable {
    var command: String
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var durationMs: Double?
    var peakMemoryBytes: UInt64?
    var wasStopped: Bool
    var resultMessage: String
}

@MainActor
protocol WorkspacePersistenceStore {
    func load() -> WorkspacePersistenceSnapshot
    func save(settings: AppSettings)
    func save(projects: [WorkspaceProject])
    func save(runHistory: [ProjectRunHistoryItem])
    func save(projectDraftsByProjectID: [String: String])
    func save(projectOutputCacheByProjectID: [String: ProjectOutputCacheEntry])
    func save(selectedProjectID: String)
}
