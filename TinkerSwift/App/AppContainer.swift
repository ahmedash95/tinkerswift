import Foundation

@MainActor
final class AppContainer {
    let persistenceStore: any WorkspacePersistenceStore

    let appModel: AppModel

    private let phpExecutionProvider: any CodeExecutionProviding
    private let codeFormatterProvider: any CodeFormattingProviding
    private let defaultProjectInstaller: any DefaultProjectInstalling

    init(
        persistenceStore: any WorkspacePersistenceStore = SQLiteWorkspaceStore(),
        phpExecutionProvider: any CodeExecutionProviding = PHPExecutionRunner(),
        codeFormatterProvider: any CodeFormattingProviding = PintCodeFormatter(),
        defaultProjectInstaller: any DefaultProjectInstalling = LaravelProjectInstaller()
    ) {
        self.persistenceStore = persistenceStore
        self.phpExecutionProvider = phpExecutionProvider
        self.codeFormatterProvider = codeFormatterProvider
        self.defaultProjectInstaller = defaultProjectInstaller
        self.appModel = AppModel(persistenceStore: persistenceStore)
    }

    func makeWorkspaceState() -> WorkspaceState {
        WorkspaceState(
            appModel: appModel,
            executionProvider: phpExecutionProvider,
            codeFormatter: codeFormatterProvider,
            defaultProjectInstaller: defaultProjectInstaller
        )
    }
}
