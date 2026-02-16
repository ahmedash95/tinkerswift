import STPluginNeon
import STTextView
import SwiftUI

struct AppKitCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let showLineNumbers: Bool
    let wrapLines: Bool
    let highlightSelectedLine: Bool
    let syntaxHighlighting: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = CodePaneTextView.scrollableTextView()
        let textView = scrollView.documentView as! CodePaneTextView

        context.coordinator.attachEditorTextView(textView)
        textView.textDelegate = context.coordinator
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.highlightSelectedLine = highlightSelectedLine
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        textView.text = text

        textView.gutterView?.textColor = .secondaryLabelColor
        textView.gutterView?.drawSeparator = true

        context.coordinator.applyEditorFont(fontSize, to: textView, force: true)
        context.coordinator.installPluginsIfNeeded(on: textView)
        context.coordinator.updateSyntaxHighlighting(syntaxHighlighting, on: textView, force: true)
        context.coordinator.updateVisualState(on: textView, force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodePaneTextView else {
            return
        }

        context.coordinator.attachEditorTextView(textView)

        if (textView.text ?? "") != text {
            context.coordinator.isSyncing = true
            textView.text = text
            context.coordinator.isSyncing = false
        }

        textView.highlightSelectedLine = highlightSelectedLine
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        context.coordinator.applyEditorFont(fontSize, to: textView)
        context.coordinator.updateSyntaxHighlighting(syntaxHighlighting, on: textView)
        context.coordinator.updateVisualState(on: textView)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        @Binding var text: String
        var isSyncing = false
        private var lastAppliedFontSize: CGFloat = 0
        private weak var textView: CodePaneTextView?
        private var neonPlugin: NeonPlugin?
        private var lastSyntaxHighlightingEnabled: Bool?
        private var lastVisualStateSignature: String?

        init(text: Binding<String>) {
            _text = text
        }

        fileprivate func attachEditorTextView(_ textView: CodePaneTextView) {
            guard self.textView !== textView else { return }

            self.textView?.onVisualStateChange = nil
            self.textView = textView
            textView.onVisualStateChange = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.updateVisualState(on: textView, force: true)
            }
        }

        func installPluginsIfNeeded(on textView: STTextView) {
            guard neonPlugin == nil else { return }
            let colorOnlyTheme = Theme(colors: Theme.default.colors, fonts: Theme.Fonts(fonts: [:]))
            let plugin = NeonPlugin(theme: colorOnlyTheme, language: .php)
            textView.addPlugin(plugin)
            neonPlugin = plugin
        }

        func updateSyntaxHighlighting(_ enabled: Bool, on textView: STTextView, force: Bool = false) {
            installPluginsIfNeeded(on: textView)
            guard force || lastSyntaxHighlightingEnabled != enabled else { return }

            lastSyntaxHighlightingEnabled = enabled
            neonPlugin?.setHighlightingEnabled(enabled)
        }

        func applyEditorFont(_ size: CGFloat, to textView: STTextView, force: Bool = false) {
            guard force || abs(lastAppliedFontSize - size) > 0.001 else { return }
            lastAppliedFontSize = size

            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            textView.font = font
            textView.gutterView?.font = font
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isSyncing, let textView = notification.object as? STTextView else {
                return
            }

            text = textView.text ?? ""
        }

        func updateVisualState(on textView: STTextView, force: Bool = false) {
            let currentSignature = visualStateSignature(for: textView)
            guard force || currentSignature != lastVisualStateSignature else {
                return
            }

            lastVisualStateSignature = currentSignature

            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                textView.backgroundColor = .textBackgroundColor
                textView.textColor = .textColor
                textView.insertionPointColor = .textColor
                textView.gutterView?.textColor = .secondaryLabelColor
                textView.gutterView?.drawSeparator = true
            }
            textView.needsLayout = true
            textView.needsDisplay = true
            textView.gutterView?.needsDisplay = true

            neonPlugin?.refreshHighlightingForAppearanceChange()
        }

        private func visualStateSignature(for textView: STTextView) -> String {
            let appearanceName = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])?.rawValue
                ?? textView.effectiveAppearance.name.rawValue
            let keyState = textView.window?.isKeyWindow == true ? "key" : "not-key"
            let activeState = NSApp.isActive ? "active" : "inactive"
            return "\(appearanceName)|\(keyState)|\(activeState)"
        }
    }
}

fileprivate final class CodePaneTextView: STTextView {
    var onVisualStateChange: (() -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconfigureObservers()
        notifyVisualStateChanged()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        notifyVisualStateChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func reconfigureObservers() {
        let center = NotificationCenter.default

        if let observedWindow {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp)

        if let window {
            observedWindow = window
            center.addObserver(
                self,
                selector: #selector(handleVisualStateNotification(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(handleVisualStateNotification(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        } else {
            observedWindow = nil
        }

        center.addObserver(
            self,
            selector: #selector(handleVisualStateNotification(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        center.addObserver(
            self,
            selector: #selector(handleVisualStateNotification(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    @objc
    private func handleVisualStateNotification(_ notification: Notification) {
        notifyVisualStateChanged()
    }

    private func notifyVisualStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onVisualStateChange?()
        }
    }
}
