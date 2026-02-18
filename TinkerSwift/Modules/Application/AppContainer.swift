import Foundation

@MainActor
final class AppContainer {
    let persistenceStore: any WorkspacePersistenceStore
    let pluginRegistry: LanguagePluginRegistry

    let appModel: AppModel

    private let phpExecutionProvider: any CodeExecutionProviding
    private let defaultProjectInstaller: any DefaultProjectInstalling

    init(
        persistenceStore: any WorkspacePersistenceStore = UserDefaultsWorkspaceStore(),
        phpExecutionProvider: any CodeExecutionProviding = PHPExecutionRunner(),
        defaultProjectInstaller: any DefaultProjectInstalling = LaravelProjectInstaller()
    ) {
        self.persistenceStore = persistenceStore
        self.pluginRegistry = LanguagePluginRegistry()
        self.phpExecutionProvider = phpExecutionProvider
        self.defaultProjectInstaller = defaultProjectInstaller
        self.appModel = AppModel(persistenceStore: persistenceStore)

        pluginRegistry.register(
            DefaultLanguagePlugin(
                id: "php",
                displayName: "PHP",
                supportedLanguageIDs: ["php"],
                completionProvider: nil,
                executionProvider: phpExecutionProvider
            )
        )
    }

    func makeWorkspaceState() -> WorkspaceState {
        WorkspaceState(
            appModel: appModel,
            executionProvider: phpExecutionProvider,
            defaultProjectInstaller: defaultProjectInstaller
        )
    }
}

private struct DefaultLanguagePlugin: LanguagePlugin {
    let id: String
    let displayName: String
    let supportedLanguageIDs: Set<String>
    let completionProvider: (any CompletionProviding)?
    let executionProvider: (any CodeExecutionProviding)?
}
