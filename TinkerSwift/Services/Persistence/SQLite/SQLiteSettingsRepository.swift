import Foundation
import SQLite3

final class SQLiteSettingsRepository {
    private enum SettingKey: String, CaseIterable {
        case appTheme = "appTheme"
        case appUIScale = "appUIScale"
        case hasCompletedOnboarding = "hasCompletedOnboarding"
        case showLineNumbers = "showLineNumbers"
        case wrapLines = "wrapLines"
        case highlightSelectedLine = "highlightSelectedLine"
        case syntaxHighlighting = "syntaxHighlighting"
        case lspCompletionEnabled = "lspCompletionEnabled"
        case lspAutoTriggerEnabled = "lspAutoTriggerEnabled"
        case autoFormatOnRunEnabled = "autoFormatOnRunEnabled"
        case lspServerPathOverride = "lspServerPathOverride"
        case phpBinaryPathOverride = "phpBinaryPathOverride"
        case dockerBinaryPathOverride = "dockerBinaryPathOverride"
        case laravelBinaryPathOverride = "laravelBinaryPathOverride"
    }

    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    func load() throws -> AppSettings {
        let statement = try database.prepare("SELECT key, value FROM workspace_settings;")
        var values: [String: String] = [:]

        while true {
            let stepResult = try statement.step()
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let key = statement.columnText(at: 0),
                  let value = statement.columnText(at: 1)
            else {
                throw SQLiteStoreError.invalidData("workspace_settings contains invalid rows.")
            }
            values[key] = value
        }

        return Self.settings(from: values)
    }

    func save(_ settings: AppSettings) throws {
        for (key, value) in Self.serializedSettings(settings) {
            let statement = try database.prepare(
                """
                INSERT INTO workspace_settings (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """
            )
            try statement.bindText(key.rawValue, at: 1)
            try statement.bindText(value, at: 2)
            _ = try statement.step()
        }
    }

    private static func serializedSettings(_ settings: AppSettings) -> [(SettingKey, String)] {
        [
            (.appTheme, settings.appTheme.rawValue),
            (.appUIScale, String(UIScaleSanitizer.sanitize(settings.appUIScale))),
            (.hasCompletedOnboarding, settings.hasCompletedOnboarding ? "1" : "0"),
            (.showLineNumbers, settings.showLineNumbers ? "1" : "0"),
            (.wrapLines, settings.wrapLines ? "1" : "0"),
            (.highlightSelectedLine, settings.highlightSelectedLine ? "1" : "0"),
            (.syntaxHighlighting, settings.syntaxHighlighting ? "1" : "0"),
            (.lspCompletionEnabled, settings.lspCompletionEnabled ? "1" : "0"),
            (.lspAutoTriggerEnabled, settings.lspAutoTriggerEnabled ? "1" : "0"),
            (.autoFormatOnRunEnabled, settings.autoFormatOnRunEnabled ? "1" : "0"),
            (.lspServerPathOverride, settings.lspServerPathOverride),
            (.phpBinaryPathOverride, settings.phpBinaryPathOverride),
            (.dockerBinaryPathOverride, settings.dockerBinaryPathOverride),
            (.laravelBinaryPathOverride, settings.laravelBinaryPathOverride)
        ]
    }

    private static func settings(from values: [String: String]) -> AppSettings {
        var settings = AppSettings(
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

        if let rawTheme = values[SettingKey.appTheme.rawValue],
           let theme = AppTheme(rawValue: rawTheme)
        {
            settings.appTheme = theme
        }

        if let rawScale = values[SettingKey.appUIScale.rawValue],
           let scale = Double(rawScale)
        {
            settings.appUIScale = UIScaleSanitizer.sanitize(scale)
        }

        settings.hasCompletedOnboarding = values[SettingKey.hasCompletedOnboarding.rawValue] == "1"
        settings.showLineNumbers = values[SettingKey.showLineNumbers.rawValue] != "0"
        settings.wrapLines = values[SettingKey.wrapLines.rawValue] != "0"
        settings.highlightSelectedLine = values[SettingKey.highlightSelectedLine.rawValue] != "0"
        settings.syntaxHighlighting = values[SettingKey.syntaxHighlighting.rawValue] != "0"
        settings.lspCompletionEnabled = values[SettingKey.lspCompletionEnabled.rawValue] != "0"
        settings.lspAutoTriggerEnabled = values[SettingKey.lspAutoTriggerEnabled.rawValue] != "0"
        settings.autoFormatOnRunEnabled = values[SettingKey.autoFormatOnRunEnabled.rawValue] != "0"
        settings.lspServerPathOverride = values[SettingKey.lspServerPathOverride.rawValue] ?? ""
        settings.phpBinaryPathOverride = values[SettingKey.phpBinaryPathOverride.rawValue] ?? ""
        settings.dockerBinaryPathOverride = values[SettingKey.dockerBinaryPathOverride.rawValue] ?? ""
        settings.laravelBinaryPathOverride = values[SettingKey.laravelBinaryPathOverride.rawValue] ?? ""

        return settings
    }
}
