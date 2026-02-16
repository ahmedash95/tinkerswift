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
            Button((isRunningScript ?? false) ? "Stop Script" : "Run Code") {
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
            .background(WindowTabbingConfigurator())
    }
}

private struct WindowTabbingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tabbingMode = .preferred
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.tabbingMode != .preferred {
                window.tabbingMode = .preferred
            }
        }
    }
}

@main
struct TinkerSwiftApp: App {
    @NSApplicationDelegateAdaptor(TinkerSwiftAppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
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
