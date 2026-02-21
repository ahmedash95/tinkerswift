import AppKit
import SwiftUI

extension Notification.Name {
    static let tinkerSwiftNewTabRequested = Notification.Name("com.ahmed.tinkerswift.newTabRequested")
    static let tinkerSwiftInsertTextAtCursor = Notification.Name("com.ahmed.tinkerswift.insertTextAtCursor")
}

@MainActor
final class TinkerSwiftAppDelegate: NSObject, NSApplicationDelegate {
    private weak var appModel: AppModel?
    private var externalWindowControllers: [NSWindowController] = []

    func setAppModel(_ appModel: AppModel) {
        self.appModel = appModel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await DebugConsoleCaptureService.shared.start()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNewTabRequest(_:)),
            name: .tinkerSwiftNewTabRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleNewTabRequest(_ notification: Notification) {
        guard let appModel else { return }

        let sourceWindow = notification.object as? NSWindow ?? NSApp.keyWindow
        let controller = WorkspaceWindowFactory.makeWorkspaceWindowController(appModel: appModel)
        guard let newWindow = controller.window else { return }

        if let sourceWindow {
            sourceWindow.tabbingMode = .preferred
            newWindow.tabbingMode = .preferred
            sourceWindow.addTabbedWindow(newWindow, ordered: .above)
        }

        controller.showWindow(nil)
        newWindow.makeKeyAndOrderFront(nil)
        trackExternalWindowController(controller)
    }

    @objc
    private func handleTrackedWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        externalWindowControllers.removeAll { $0.window === closingWindow }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: closingWindow)
    }

    @objc
    private func handleWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.tabbingMode != .preferred {
            window.tabbingMode = .preferred
        }
    }

    private func trackExternalWindowController(_ controller: NSWindowController) {
        externalWindowControllers.append(controller)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTrackedWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: controller.window
        )
    }
}
