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
    @Binding var appUIScale: Double
    @FocusedValue(\.runCodeAction) private var runCodeAction

    var body: some Commands {
        CommandMenu("Run") {
            Button("Run Code") {
                runCodeAction?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(runCodeAction == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") {
                appUIScale = min(appUIScale + 0.1, 3.0)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                appUIScale = max(appUIScale - 0.1, 0.6)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Actual Size") {
                appUIScale = 1.0
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}

@main
struct TinkerSwiftApp: App {
    @AppStorage("app.uiScale") private var appUIScale = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            TinkerSwiftCommands(appUIScale: $appUIScale)
        }
    }
}
