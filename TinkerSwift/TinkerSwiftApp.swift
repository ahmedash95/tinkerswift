import AppKit
import SwiftUI

private struct RunCodeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct IsRunningKey: FocusedValueKey {
    typealias Value = Bool
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
}

private struct TinkerSwiftCommands: Commands {
    let appModel: AppModel

    @FocusedValue(\.runCodeAction) private var runCodeAction
    @FocusedValue(\.isRunningScript) private var isRunningScript

    var body: some Commands {
        CommandMenu("Run") {
            Button((isRunningScript ?? false) ? "Restart Code" : "Run Code") {
                runCodeAction?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(runCodeAction == nil)
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
                appModel.appUIScale = min(appModel.appUIScale + 0.1, 3.0)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                appModel.appUIScale = max(appModel.appUIScale - 0.1, 0.6)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Actual Size") {
                appModel.appUIScale = 1.0
            }
            .keyboardShortcut("0", modifiers: [.command])
        }

        CommandMenu("Debug") {
            Button("Open Console") {
                DebugConsoleWindowManager.shared.show()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }

        CommandMenu("Editor") {
            Button("Trigger Completion") {
                NSApp.sendAction(#selector(NSStandardKeyBindingResponding.complete(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

struct WorkspaceRootView: View {
    let appModel: AppModel
    @State private var workspaceState: WorkspaceState

    init(appModel: AppModel) {
        self.appModel = appModel
        _workspaceState = State(initialValue: WorkspaceState(appModel: appModel))
    }

    var body: some View {
        ContentView()
            .environment(appModel)
            .environment(workspaceState)
    }
}

@main
struct TinkerSwiftApp: App {
    @NSApplicationDelegateAdaptor(TinkerSwiftAppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceRootView(appModel: appModel)
                .onAppear {
                    appDelegate.setAppModel(appModel)
                }
        }
        .commands {
            TinkerSwiftCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}
