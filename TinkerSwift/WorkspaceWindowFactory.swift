import AppKit
import SwiftUI

@MainActor
enum WorkspaceWindowFactory {
    static func makeWorkspaceWindowController(appModel: AppModel) -> NSWindowController {
        let rootView = WorkspaceRootView(appModel: appModel)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "TinkerSwift"
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.minSize = NSSize(width: 1000, height: 620)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred

        let windowController = NSWindowController(window: window)
        windowController.shouldCascadeWindows = true
        return windowController
    }
}
