import SwiftUI

@main
struct TinkerSwiftApp: App {
    @AppStorage("app.uiScale") private var appUIScale = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
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
}
