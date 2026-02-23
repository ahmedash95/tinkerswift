import AppKit
import SwiftUI

private struct RunCodeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct IsRunningKey: FocusedValueKey {
    typealias Value = Bool
}

private struct WorkspaceSymbolSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct DocumentSymbolSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var runCodeAction: (() -> Void)? {
        get { self[RunCodeActionKey.self] }
        set { self[RunCodeActionKey.self] = newValue }
    }

    var isRunningScript: Bool? {
        get { self[IsRunningKey.self] }
        set { self[IsRunningKey.self] = newValue }
    }

    var workspaceSymbolSearchAction: (() -> Void)? {
        get { self[WorkspaceSymbolSearchActionKey.self] }
        set { self[WorkspaceSymbolSearchActionKey.self] = newValue }
    }

    var documentSymbolSearchAction: (() -> Void)? {
        get { self[DocumentSymbolSearchActionKey.self] }
        set { self[DocumentSymbolSearchActionKey.self] = newValue }
    }
}

private struct TinkerSwiftCommands: Commands {
    let appModel: AppModel

    @FocusedValue(\.runCodeAction) private var runCodeAction
    @FocusedValue(\.isRunningScript) private var isRunningScript
    @FocusedValue(\.workspaceSymbolSearchAction) private var workspaceSymbolSearchAction
    @FocusedValue(\.documentSymbolSearchAction) private var documentSymbolSearchAction

    var body: some Commands {
        CommandMenu("Run") {
            Button((isRunningScript ?? false) ? "Restart Code" : "Run Code") {
                runCodeAction?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(runCodeAction == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                NSApp.sendAction(#selector(TinkerSwiftAppDelegate.checkForUpdates(_:)), to: nil, from: nil)
            }
        }

        CommandGroup(after: .newItem) {
            Button("New Tab") {
                NotificationCenter.default.post(name: .tinkerSwiftNewTabRequested, object: NSApp.keyWindow)
            }
            .keyboardShortcut("t", modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Divider()

            Button("Zoom In") {
                appModel.appUIScale = UIScaleSanitizer.sanitize(appModel.appUIScale + 0.1)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                appModel.appUIScale = UIScaleSanitizer.sanitize(appModel.appUIScale - 0.1)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Actual Size") {
                appModel.appUIScale = UIScaleSanitizer.defaultScale
            }
            .keyboardShortcut("0", modifiers: [.command])
        }

        CommandMenu("Editor") {
            Button("Trigger Completion") {
                NSApp.sendAction(#selector(NSStandardKeyBindingResponding.complete(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Button("Search Workspace Symbols") {
                workspaceSymbolSearchAction?()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(workspaceSymbolSearchAction == nil)

            Button("Search Document Symbols") {
                documentSymbolSearchAction?()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(documentSymbolSearchAction == nil)
        }
    }
}

struct WorkspaceRootView: View {
    private let appModel: AppModel
    @State private var workspaceState: WorkspaceState
    @State private var isShowingOnboarding = false
    @State private var isShowingStartupRecoveryAlert = false

    init(appModel: AppModel) {
        self.appModel = appModel
        _workspaceState = State(initialValue: WorkspaceState(appModel: appModel))
    }

    init(container: AppContainer) {
        self.appModel = container.appModel
        _workspaceState = State(initialValue: container.makeWorkspaceState())
    }

    var body: some View {
        ContentView()
            .environment(appModel)
            .environment(workspaceState)
            .sheet(isPresented: $isShowingOnboarding) {
                OnboardingSheet(isPresented: $isShowingOnboarding)
                    .environment(appModel)
                    .environment(workspaceState)
            }
            .alert("Failed to Read Application Data", isPresented: $isShowingStartupRecoveryAlert) {
                Button("Start Over") {
                    appModel.dismissStartupRecoveryMessage()
                }
            } message: {
                Text(appModel.startupRecoveryMessage ?? "")
            }
            .onAppear {
                if !appModel.hasCompletedOnboarding {
                    isShowingOnboarding = true
                }
                isShowingStartupRecoveryAlert = appModel.startupRecoveryMessage != nil
            }
            .onChange(of: appModel.hasCompletedOnboarding) { _, completed in
                if completed {
                    isShowingOnboarding = false
                }
            }
            .onChange(of: appModel.startupRecoveryMessage) { _, message in
                isShowingStartupRecoveryAlert = message != nil
            }
    }
}

@main
struct TinkerSwiftApp: App {
    @NSApplicationDelegateAdaptor(TinkerSwiftAppDelegate.self) private var appDelegate
    @State private var container = AppContainer()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView(container: container)
                .onAppear {
                    appDelegate.setAppModel(container.appModel)
                    container.appModel.appTheme.applyAppearance()
                }
        }
        .commands {
            TinkerSwiftCommands(appModel: container.appModel)
        }

        Settings {
            SettingsView()
                .environment(container.appModel)
        }
    }
}
