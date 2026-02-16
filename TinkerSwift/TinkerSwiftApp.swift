import SwiftUI

private struct RunCodeActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var runCodeAction: (() -> Void)? {
        get { self[RunCodeActionKey.self] }
        set { self[RunCodeActionKey.self] = newValue }
    }
}

private struct TinkerSwiftCommands: Commands {
    let appState: TinkerSwiftState

    @FocusedValue(\.runCodeAction) private var runCodeAction

    var body: some Commands {
        CommandMenu("Run") {
            Button(appState.isRunning ? "Stop Script" : "Run Code") {
                runCodeAction?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(runCodeAction == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()

            Button("Zoom In") {
                appState.appUIScale = min(appState.appUIScale + 0.1, 3.0)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                appState.appUIScale = max(appState.appUIScale - 0.1, 0.6)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Actual Size") {
                appState.appUIScale = 1.0
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}

@main
struct TinkerSwiftApp: App {
    @State private var appState = TinkerSwiftState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .commands {
            TinkerSwiftCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
