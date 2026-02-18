import Foundation
import AppKit
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
    let isEditable: Bool
    let projectPath: String
    let lspCompletionEnabled: Bool
    let lspAutoTriggerEnabled: Bool
    let lspServerPathOverride: String

    init(
        text: Binding<String>,
        fontSize: CGFloat,
        showLineNumbers: Bool,
        wrapLines: Bool,
        highlightSelectedLine: Bool,
        syntaxHighlighting: Bool,
        isEditable: Bool = true,
        projectPath: String = "",
        lspCompletionEnabled: Bool = false,
        lspAutoTriggerEnabled: Bool = true,
        lspServerPathOverride: String = ""
    ) {
        _text = text
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.wrapLines = wrapLines
        self.highlightSelectedLine = highlightSelectedLine
        self.syntaxHighlighting = syntaxHighlighting
        self.isEditable = isEditable
        self.projectPath = projectPath
        self.lspCompletionEnabled = lspCompletionEnabled
        self.lspAutoTriggerEnabled = lspAutoTriggerEnabled
        self.lspServerPathOverride = lspServerPathOverride
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorHostScrollView(frame: .zero)
        let textView = CodePaneTextView(frame: .zero)

        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.documentView = textView

        context.coordinator.attachEditorTextView(textView)
        textView.textDelegate = context.coordinator
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.isVerticallyResizable = true
        textView.isEditable = isEditable
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
        context.coordinator.configureLSP(
            projectPath: projectPath,
            enabled: isEditable && lspCompletionEnabled,
            autoTriggerEnabled: lspAutoTriggerEnabled,
            serverPathOverride: lspServerPathOverride,
            currentText: textView.text ?? ""
        )
        scrollView.stretchDocumentViewToViewportIfNeeded()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodePaneTextView else {
            return
        }

        scrollView.backgroundColor = .clear
        context.coordinator.attachEditorTextView(textView)

        if (textView.text ?? "") != text {
            context.coordinator.isSyncing = true
            textView.text = text
            context.coordinator.isSyncing = false
            context.coordinator.scheduleDocumentSync(text: text, immediate: true)
        }

        textView.highlightSelectedLine = highlightSelectedLine
        textView.isEditable = isEditable
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        context.coordinator.applyEditorFont(fontSize, to: textView)
        context.coordinator.updateSyntaxHighlighting(syntaxHighlighting, on: textView)
        context.coordinator.updateVisualState(on: textView)
        context.coordinator.configureLSP(
            projectPath: projectPath,
            enabled: isEditable && lspCompletionEnabled,
            autoTriggerEnabled: lspAutoTriggerEnabled,
            serverPathOverride: lspServerPathOverride,
            currentText: textView.text ?? ""
        )
        (scrollView as? EditorHostScrollView)?.stretchDocumentViewToViewportIfNeeded()
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

        private let lspService = PHPLSPService.shared
        private var lspEnabled = false
        private var lspAutoTriggerEnabled = true
        private var currentProjectPath = ""
        private var currentDocumentURI = ""
        private var lspServerPathOverride = ""
        private var pendingDocumentSyncTask: Task<Void, Never>?
        private var pendingDebouncedCompletionTask: Task<Void, Never>?
        private var pendingTriggerCharacter: String?
        private var latestCompletionRequestToken: UInt64 = 0
        private var lastLSPConfigurationSignature = ""
        private var completionPopupFontSize: CGFloat = 12
        private let completionViewController = ScaledCompletionViewController()

        init(text: Binding<String>) {
            _text = text
        }

        deinit {
            pendingDocumentSyncTask?.cancel()
            pendingDebouncedCompletionTask?.cancel()
            if lspEnabled, !currentDocumentURI.isEmpty {
                let uri = currentDocumentURI
                Task {
                    await PHPLSPService.shared.closeDocument(uri: uri)
                }
            }
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
            completionPopupFontSize = Self.completionPopupFontSize(forEditorFontSize: size)
            completionViewController.popupFontSize = completionPopupFontSize

            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            textView.font = font
            textView.gutterView?.font = font
        }

        func configureLSP(
            projectPath: String,
            enabled: Bool,
            autoTriggerEnabled: Bool,
            serverPathOverride: String,
            currentText: String
        ) {
            let normalizedProjectPath = Self.normalizedProjectPath(projectPath)
            let newDocumentURI = Self.documentURI(forProjectPath: normalizedProjectPath)
            let previousDocumentURI = currentDocumentURI
            let wasEnabled = lspEnabled

            if lspServerPathOverride != serverPathOverride {
                lspServerPathOverride = serverPathOverride
                Task {
                    await lspService.setServerPathOverride(serverPathOverride)
                }
            }

            lspAutoTriggerEnabled = autoTriggerEnabled
            lspEnabled = enabled
            currentProjectPath = normalizedProjectPath
            currentDocumentURI = newDocumentURI

            let signature = "\(enabled)|\(autoTriggerEnabled)|\(normalizedProjectPath)|\(newDocumentURI)|\(serverPathOverride)"
            if signature != lastLSPConfigurationSignature {
                lastLSPConfigurationSignature = signature
                logEditor("configure lsp enabled=\(enabled) autoTrigger=\(autoTriggerEnabled) project=\(normalizedProjectPath)")
            }

            if wasEnabled,
               !previousDocumentURI.isEmpty,
               (previousDocumentURI != newDocumentURI || !enabled)
            {
                Task {
                    await lspService.closeDocument(uri: previousDocumentURI)
                }
            }

            if enabled {
                scheduleDocumentSync(text: currentText, immediate: true)
            } else {
                pendingDocumentSyncTask?.cancel()
                pendingDebouncedCompletionTask?.cancel()
            }
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isSyncing, let textView = notification.object as? STTextView else {
                return
            }

            let currentText = textView.text ?? ""
            text = currentText
            scheduleDocumentSync(text: currentText)
        }

        func textView(_ textView: STTextView, didChangeTextIn affectedCharRange: NSTextRange, replacementString: String) {
            guard lspEnabled else { return }
            scheduleDocumentSync(text: textView.text ?? "")

            guard lspAutoTriggerEnabled else {
                pendingDebouncedCompletionTask?.cancel()
                return
            }

            if let triggerCharacter = Self.triggerCharacter(from: replacementString) {
                pendingDebouncedCompletionTask?.cancel()
                pendingTriggerCharacter = triggerCharacter
                logEditor("auto-trigger completion char='\(triggerCharacter)'")
                DispatchQueue.main.async {
                    textView.complete(nil)
                }
                return
            }

            guard Self.shouldDebounceCompletion(from: replacementString) else {
                pendingDebouncedCompletionTask?.cancel()
                return
            }

            pendingDebouncedCompletionTask?.cancel()
            pendingDebouncedCompletionTask = Task { [weak textView] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let textView, self.lspEnabled, self.lspAutoTriggerEnabled else { return }
                    self.pendingTriggerCharacter = nil
                    self.logEditor("auto-refresh completion (debounced)")
                    textView.complete(nil)
                }
            }
        }

        func textView(_ textView: STTextView, completionItemsAtLocation location: any NSTextLocation) async -> [any STCompletionItem]? {
            guard lspEnabled, !currentDocumentURI.isEmpty else {
                return []
            }

            latestCompletionRequestToken &+= 1
            let requestToken = latestCompletionRequestToken

            let fullText = textView.text ?? ""
            let documentStart = textView.textLayoutManager.documentRange.location
            let utf16Offset = textView.textLayoutManager.offset(from: documentStart, to: location)
            let triggerCharacter = pendingTriggerCharacter
            pendingTriggerCharacter = nil

            let position = LSPPositionConverter.position(in: fullText, utf16Offset: utf16Offset)
            logEditor("request completion line=\(position.line) char=\(position.character) trigger=\(triggerCharacter ?? "manual")")

            let completionItems = await lspService.completionItems(
                uri: currentDocumentURI,
                projectPath: currentProjectPath,
                text: fullText,
                utf16Offset: utf16Offset,
                triggerCharacter: triggerCharacter
            )

            guard requestToken == latestCompletionRequestToken else {
                logEditor("discard stale completion response token=\(requestToken)")
                return []
            }

            logEditor("completion response count=\(completionItems.count)")
            return completionItems.map {
                LSPCompletionEntry(candidate: $0, fontSize: completionPopupFontSize)
            }
        }

        func textViewCompletionViewController(_ textView: STTextView) -> any STCompletionViewControllerProtocol {
            completionViewController.popupFontSize = completionPopupFontSize
            return completionViewController
        }

        func textView(_ textView: STTextView, insertCompletionItem item: any STCompletionItem) {
            guard let completionItem = item as? LSPCompletionEntry else {
                return
            }

            pendingDebouncedCompletionTask?.cancel()
            logEditor(
                "insert completion label='\(completionItem.candidate.label)' additionalEdits=\(completionItem.candidate.additionalTextEdits.count)"
            )
            insertCompletion(completionItem.candidate, into: textView)
            scheduleDocumentSync(text: textView.text ?? "", immediate: true)
        }

        func scheduleDocumentSync(text: String, immediate: Bool = false) {
            guard lspEnabled, !currentDocumentURI.isEmpty else {
                return
            }

            pendingDocumentSyncTask?.cancel()

            let uri = currentDocumentURI
            let projectPath = currentProjectPath
            pendingDocumentSyncTask = Task {
                if !immediate {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }

                guard !Task.isCancelled else { return }

                await PHPLSPService.shared.openOrUpdateDocument(
                    uri: uri,
                    projectPath: projectPath,
                    text: text,
                    languageID: "php"
                )
            }
        }

        func updateVisualState(on textView: STTextView, force: Bool = false) {
            let currentSignature = visualStateSignature(for: textView)
            guard force || currentSignature != lastVisualStateSignature else {
                return
            }

            lastVisualStateSignature = currentSignature

            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                textView.backgroundColor = .clear
                textView.textColor = .textColor
                textView.insertionPointColor = .textColor
                textView.gutterView?.textColor = .secondaryLabelColor
                textView.gutterView?.drawSeparator = true
            }

            neonPlugin?.refreshHighlightingForAppearanceChange()
        }

        private func visualStateSignature(for textView: STTextView) -> String {
            let appearanceName = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])?.rawValue
                ?? textView.effectiveAppearance.name.rawValue
            let keyState = textView.window?.isKeyWindow == true ? "key" : "not-key"
            let activeState = NSApp.isActive ? "active" : "inactive"
            return "\(appearanceName)|\(keyState)|\(activeState)"
        }

        private func insertCompletion(_ completion: LSPCompletionCandidate, into textView: STTextView) {
            let currentText = textView.text ?? ""
            let selectedRange = textView.selectedRange()
            let primaryRange: NSRange
            let primaryText: String
            let primarySelectionRange: NSRange?
            if let textEdit = completion.primaryTextEdit,
               let replaceRange = Self.nsRange(for: textEdit, in: currentText)
            {
                primaryRange = replaceRange
                primaryText = textEdit.newText
                primarySelectionRange = textEdit.selectedRangeInNewText
            } else if selectedRange.location != NSNotFound, selectedRange.length > 0 {
                primaryRange = selectedRange
                primaryText = completion.insertText.isEmpty ? completion.label : completion.insertText
                primarySelectionRange = completion.insertSelectionRange
            } else {
                let cursor = selectedRange.location == NSNotFound ? 0 : selectedRange.location
                primaryRange = Self.partialTokenRange(in: currentText, cursorLocation: cursor)
                primaryText = completion.insertText.isEmpty ? completion.label : completion.insertText
                primarySelectionRange = completion.insertSelectionRange
            }

            var operations: [(range: NSRange, text: String, isPrimary: Bool, selectedRangeInInsertedText: NSRange?)] = [
                (range: primaryRange, text: primaryText, isPrimary: true, selectedRangeInInsertedText: primarySelectionRange)
            ]

            if !completion.additionalTextEdits.isEmpty {
                for additionalEdit in completion.additionalTextEdits {
                    guard let range = Self.nsRange(for: additionalEdit, in: currentText) else {
                        continue
                    }
                    operations.append((range: range, text: additionalEdit.newText, isPrimary: false, selectedRangeInInsertedText: nil))
                }
            }

            let sortedOperations = operations.sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length > rhs.range.length
                }
                return lhs.range.location > rhs.range.location
            }

            var finalSelection: NSRange?
            for operation in sortedOperations {
                textView.replaceCharacters(in: operation.range, with: operation.text)

                let insertedLength = (operation.text as NSString).length
                let delta = insertedLength - operation.range.length

                if operation.isPrimary {
                    if let selectedRangeInInsertedText = operation.selectedRangeInInsertedText {
                        finalSelection = NSRange(
                            location: operation.range.location + selectedRangeInInsertedText.location,
                            length: selectedRangeInInsertedText.length
                        )
                    } else {
                        finalSelection = NSRange(location: operation.range.location + insertedLength, length: 0)
                    }
                } else if let currentSelection = finalSelection, operation.range.location <= currentSelection.location {
                    finalSelection = NSRange(
                        location: max(0, currentSelection.location + delta),
                        length: currentSelection.length
                    )
                }
            }

            if let finalSelection {
                textView.textSelection = finalSelection
            }
        }

        private static func normalizedProjectPath(_ path: String) -> String {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
            }

            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        }

        private static func documentURI(forProjectPath projectPath: String) -> String {
            URL(fileURLWithPath: projectPath, isDirectory: true)
                .appendingPathComponent(".tinkerswift_scratch.php")
                .standardizedFileURL
                .absoluteString
        }

        private static func triggerCharacter(from replacementString: String) -> String? {
            guard replacementString.count == 1 else {
                return nil
            }

            let candidate = String(replacementString)
            switch candidate {
            case ".", ":", ">", "\\":
                return candidate
            default:
                return nil
            }
        }

        private static func shouldDebounceCompletion(from replacementString: String) -> Bool {
            if replacementString.isEmpty {
                return true
            }

            guard replacementString.count == 1 else {
                return false
            }

            let value = (replacementString as NSString).character(at: 0)
            return isTokenCharacter(value) || value == 92 // \
        }

        private static func partialTokenRange(in text: String, cursorLocation: Int) -> NSRange {
            let nsText = text as NSString
            let boundedCursor = min(max(0, cursorLocation), nsText.length)

            var start = boundedCursor
            while start > 0 {
                let scalar = nsText.character(at: start - 1)
                if !isTokenCharacter(scalar) {
                    break
                }
                start -= 1
            }

            var end = boundedCursor
            while end < nsText.length {
                let scalar = nsText.character(at: end)
                if !isTokenCharacter(scalar) {
                    break
                }
                end += 1
            }

            return NSRange(location: start, length: end - start)
        }

        private static func isTokenCharacter(_ value: unichar) -> Bool {
            if value == 95 || value == 36 { // _ and $
                return true
            }
            if (48...57).contains(value) {
                return true
            }
            if (65...90).contains(value) {
                return true
            }
            if (97...122).contains(value) {
                return true
            }
            return false
        }

        private static func completionPopupFontSize(forEditorFontSize size: CGFloat) -> CGFloat {
            max(11, size)
        }

        private static func nsRange(for textEdit: LSPTextEdit, in text: String) -> NSRange? {
            let start = LSPPositionConverter.utf16Offset(
                in: text,
                line: textEdit.startLine,
                character: textEdit.startCharacter
            )
            let end = LSPPositionConverter.utf16Offset(
                in: text,
                line: textEdit.endLine,
                character: textEdit.endCharacter
            )

            guard end >= start else {
                return nil
            }

            return NSRange(location: start, length: end - start)
        }

        private func logEditor(_ message: String) {
            DebugConsoleStore.shared.append(stream: .app, message: "[EditorCompletion] \(message)")
        }
    }
}

fileprivate final class EditorHostScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize {
        NSSize(width: 1, height: 1)
    }

    override func layout() {
        super.layout()
        stretchDocumentViewToViewportIfNeeded()
    }

    func stretchDocumentViewToViewportIfNeeded() {
        guard let documentView else { return }

        let viewportSize = contentView.bounds.size
        var frame = documentView.frame
        var needsUpdate = false

        if frame.width < viewportSize.width {
            frame.size.width = viewportSize.width
            needsUpdate = true
        }
        if frame.height < viewportSize.height {
            frame.size.height = viewportSize.height
            needsUpdate = true
        }

        if needsUpdate {
            documentView.frame = frame
        }
    }
}

fileprivate final class CodePaneTextView: STTextView {
    var onVisualStateChange: (() -> Void)?
    private weak var observedWindow: NSWindow?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

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

private struct LSPTextEdit: Sendable {
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
    let newText: String
    let selectedRangeInNewText: NSRange?
}

private struct LSPResolvedInsertText: Sendable {
    let text: String
    let selectedRange: NSRange?
}

private struct LSPCompletionCandidate: Sendable {
    let id: String
    let label: String
    let detail: String?
    let documentation: String?
    let sortText: String
    let insertText: String
    let insertSelectionRange: NSRange?
    let primaryTextEdit: LSPTextEdit?
    let additionalTextEdits: [LSPTextEdit]
    let kind: LSPCompletionKind?
}

private extension LSPCompletionCandidate {
    func popupSignatureSummary(maxLength: Int = 180) -> String {
        if let detail = normalizedSingleLine(detail, maxLength: maxLength) {
            return detail
        }
        if let inferred = inferredSignature(maxLength: maxLength) {
            return inferred
        }
        if let documentation = normalizedSingleLine(documentation, maxLength: maxLength) {
            return documentation
        }
        return label
    }

    private func inferredSignature(maxLength: Int) -> String? {
        let insert = insertText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !insert.isEmpty,
           insert != label,
           let normalized = normalizedSingleLine(insert, maxLength: maxLength)
        {
            return normalized
        }

        guard let kind else {
            return nil
        }

        switch kind {
        case .method, .function, .constructor:
            return "\(label)(...)"
        case .class, .interface, .struct, .enum:
            return "\(kind.displayName): \(label)"
        case .property, .field, .variable, .constant:
            return "\(kind.displayName): \(label)"
        default:
            return kind.displayName
        }
    }

    private func normalizedSingleLine(_ source: String?, maxLength: Int) -> String? {
        guard let source else { return nil }
        let singleLine = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !singleLine.isEmpty else {
            return nil
        }

        if singleLine.count > maxLength {
            let index = singleLine.index(singleLine.startIndex, offsetBy: maxLength - 3)
            return "\(singleLine[..<index])..."
        }
        return singleLine
    }
}

private struct LSPCompletionEntry: STCompletionItem {
    let id: String
    let candidate: LSPCompletionCandidate
    let fontSize: CGFloat

    init(candidate: LSPCompletionCandidate, fontSize: CGFloat) {
        self.id = candidate.id
        self.candidate = candidate
        self.fontSize = fontSize
    }

    var view: NSView {
        MainActor.assumeIsolated {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6

            if let icon = NSImage(
                systemSymbolName: candidate.kind?.symbolName ?? LSPCompletionKind.defaultSymbolName,
                accessibilityDescription: nil
            ) {
                let imageView = NSImageView(image: icon)
                imageView.contentTintColor = candidate.kind?.color ?? .secondaryLabelColor
                imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: max(10, fontSize - 1), weight: .regular)
                imageView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 13),
                    imageView.heightAnchor.constraint(equalToConstant: 13)
                ])
                row.addArrangedSubview(imageView)
            }

            let titleLabel = CompletionPopupLabel(labelWithString: candidate.label)
            titleLabel.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            titleLabel.textColor = .labelColor
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.drawsBackground = false
            titleLabel.isBezeled = false
            titleLabel.isBordered = false
            row.addArrangedSubview(titleLabel)

            if let detail = candidate.detail, !detail.isEmpty {
                let detailLabel = CompletionPopupLabel(labelWithString: detail)
                detailLabel.font = NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 1), weight: .regular)
                detailLabel.textColor = .secondaryLabelColor
                detailLabel.lineBreakMode = .byTruncatingTail
                detailLabel.maximumNumberOfLines = 1
                detailLabel.drawsBackground = false
                detailLabel.isBezeled = false
                detailLabel.isBordered = false
                row.addArrangedSubview(detailLabel)
            }

            return row
        }
    }
}

private final class CompletionPopupLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
}

private final class CompletionPopupRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected,
              let context = NSGraphicsContext.current?.cgContext
        else {
            return
        }

        context.saveGState()
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fillColor = isDark
            ? NSColor.systemBlue.withAlphaComponent(0.38)
            : NSColor.systemBlue.withAlphaComponent(0.20)
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        context.restoreGState()
    }
}

private final class ScaledCompletionViewController: STCompletionViewController {
    var popupFontSize: CGFloat = 12 {
        didSet {
            applyRowMetrics()
        }
    }

    override var items: [any STCompletionItem] {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.applyRowMetrics()
                self?.refreshSignatureHeader()
            }
        }
    }

    private let signatureContainer = NSVisualEffectView(frame: .zero)
    private let signatureLabel = CompletionPopupLabel(labelWithString: "")
    private let signatureSeparator = NSView(frame: .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSignatureHeader()
        applyRowMetrics()
        refreshSignatureHeader()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSignatureHeader()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshSignatureHeader()
        }
    }

    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionPopupRowView(frame: .zero)
    }

    private func applyRowMetrics() {
        guard isViewLoaded else { return }
        let rowHeight = max(22, ceil(popupFontSize + 10))
        if abs(tableView.rowHeight - rowHeight) > 0.5 {
            tableView.rowHeight = rowHeight
            if !items.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
            }
        }

        signatureLabel.font = NSFont.monospacedSystemFont(ofSize: max(10, popupFontSize - 1), weight: .regular)
        layoutSignatureHeader()
    }

    private var signatureHeaderHeight: CGFloat {
        max(24, ceil(popupFontSize + 12))
    }

    private func configureSignatureHeader() {
        signatureContainer.blendingMode = .withinWindow
        signatureContainer.material = .menu
        signatureContainer.state = .followsWindowActiveState
        signatureContainer.wantsLayer = true
        signatureContainer.layer?.cornerRadius = 6
        signatureContainer.layer?.cornerCurve = .continuous

        signatureLabel.lineBreakMode = .byTruncatingTail
        signatureLabel.maximumNumberOfLines = 1
        signatureLabel.textColor = .secondaryLabelColor
        signatureLabel.alignment = .left

        signatureSeparator.wantsLayer = true
        signatureSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        signatureContainer.addSubview(signatureLabel)
        view.addSubview(signatureContainer)
        view.addSubview(signatureSeparator)
    }

    private func layoutSignatureHeader() {
        guard isViewLoaded else { return }

        let inset: CGFloat = 6
        let headerHeight = signatureHeaderHeight
        let width = max(0, view.bounds.width - (inset * 2))
        let headerY = max(0, view.bounds.height - headerHeight - inset)
        signatureContainer.frame = NSRect(x: inset, y: headerY, width: width, height: headerHeight)
        signatureLabel.frame = signatureContainer.bounds.insetBy(dx: 8, dy: 4)

        signatureSeparator.frame = NSRect(
            x: inset,
            y: max(0, signatureContainer.frame.minY - 4),
            width: width,
            height: 1
        )

        let topInset = headerHeight + (inset * 2)
        if let scrollView = tableView.enclosingScrollView {
            var insets = scrollView.contentInsets
            if abs(insets.top - topInset) > 0.5 {
                insets.top = topInset
                scrollView.contentInsets = insets
            }
        }
    }

    private func refreshSignatureHeader() {
        guard isViewLoaded else { return }
        guard !items.isEmpty else {
            signatureContainer.isHidden = true
            signatureSeparator.isHidden = true
            signatureLabel.stringValue = ""
            return
        }

        let selected = tableView.selectedRow
        let rowIndex = (selected >= 0 && selected < items.count) ? selected : 0
        guard let entry = items[rowIndex] as? LSPCompletionEntry else {
            signatureContainer.isHidden = true
            signatureSeparator.isHidden = true
            signatureLabel.stringValue = ""
            return
        }

        signatureLabel.stringValue = entry.candidate.popupSignatureSummary()
        signatureContainer.isHidden = false
        signatureSeparator.isHidden = false
    }
}

private enum LSPCompletionKind: Int, Sendable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case `struct` = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25

    static let defaultSymbolName = "textformat"

    var symbolName: String {
        switch self {
        case .method:
            return "function"
        case .function:
            return "fx"
        case .constructor:
            return "wrench.and.screwdriver"
        case .field:
            return "line.3.horizontal.decrease.circle"
        case .variable:
            return "character.textbox"
        case .class:
            return "c.square"
        case .interface:
            return "square.stack.3d.up"
        case .module:
            return "shippingbox"
        case .property:
            return "slider.horizontal.3"
        case .unit:
            return "ruler"
        case .value:
            return "number"
        case .enum:
            return "list.number"
        case .keyword:
            return "captions.bubble"
        case .snippet:
            return "chevron.left.forwardslash.chevron.right"
        case .color:
            return "paintpalette"
        case .file:
            return "doc.text"
        case .reference:
            return "link"
        case .folder:
            return "folder"
        case .enumMember:
            return "list.bullet"
        case .constant:
            return "number.square"
        case .struct:
            return "cube.box"
        case .event:
            return "bolt.circle"
        case .operator:
            return "plus.slash.minus"
        case .typeParameter:
            return "tag"
        case .text:
            return Self.defaultSymbolName
        }
    }

    var color: NSColor {
        switch self {
        case .method, .function, .constructor:
            return .systemBlue
        case .class, .interface, .struct, .enum:
            return .systemOrange
        case .property, .field, .variable, .constant:
            return .systemGreen
        case .keyword, .operator:
            return .systemPurple
        case .module, .file, .folder, .reference:
            return .systemBrown
        default:
            return .secondaryLabelColor
        }
    }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .method: return "Method"
        case .function: return "Function"
        case .constructor: return "Constructor"
        case .field: return "Field"
        case .variable: return "Variable"
        case .class: return "Class"
        case .interface: return "Interface"
        case .module: return "Module"
        case .property: return "Property"
        case .unit: return "Unit"
        case .value: return "Value"
        case .enum: return "Enum"
        case .keyword: return "Keyword"
        case .snippet: return "Snippet"
        case .color: return "Color"
        case .file: return "File"
        case .reference: return "Reference"
        case .folder: return "Folder"
        case .enumMember: return "Enum Member"
        case .constant: return "Constant"
        case .struct: return "Struct"
        case .event: return "Event"
        case .operator: return "Operator"
        case .typeParameter: return "Type Parameter"
        }
    }
}

private enum LSPError: Error {
    case launchFailed(String)
    case invalidResponse
    case timeout
    case disconnected
    case serverError(String)
}

private struct LSPDocumentState: Sendable {
    var version: Int
    var sourceText: String
    var lspText: String
    var lineOffset: Int
}

private struct LSPPreparedDocument: Sendable {
    let text: String
    let lineOffset: Int
    let didWrapSnippet: Bool
}

private struct LSPParsedCompletionItem: Sendable {
    let candidate: LSPCompletionCandidate
    let rawObject: [String: JSONValue]
}

private enum JSONValue: Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(value)
    }

    var anyValue: Any {
        switch self {
        case let .object(value):
            var object: [String: Any] = [:]
            object.reserveCapacity(value.count)
            for (key, item) in value {
                object[key] = item.anyValue
            }
            return object
        case let .array(value):
            return value.map(\.anyValue)
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        }
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

private enum JSONValueConverter {
    static func convert(_ value: Any) -> JSONValue? {
        switch value {
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(value.count)
            for (key, item) in value {
                guard let converted = convert(item) else { return nil }
                object[key] = converted
            }
            return .object(object)
        case let value as [Any]:
            var array: [JSONValue] = []
            array.reserveCapacity(value.count)
            for item in value {
                guard let converted = convert(item) else { return nil }
                array.append(converted)
            }
            return .array(array)
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

private enum LSPPositionConverter {
    static func position(in text: String, utf16Offset: Int) -> (line: Int, character: Int) {
        let boundedOffset = min(max(0, utf16Offset), text.utf16.count)
        var line = 0
        var lineStart = 0
        var offset = 0

        for scalar in text.utf16 {
            guard offset < boundedOffset else {
                break
            }
            if scalar == 10 {
                line += 1
                lineStart = offset + 1
            }
            offset += 1
        }

        return (line: line, character: boundedOffset - lineStart)
    }

    static func utf16Offset(in text: String, line: Int, character: Int) -> Int {
        let boundedLine = max(0, line)
        let boundedCharacter = max(0, character)

        var currentLine = 0
        var offset = 0
        var lineStart = 0

        for scalar in text.utf16 {
            if currentLine == boundedLine {
                break
            }
            offset += 1
            if scalar == 10 {
                currentLine += 1
                lineStart = offset
            }
        }

        let desiredOffset = lineStart + boundedCharacter
        return min(max(0, desiredOffset), text.utf16.count)
    }
}

private actor PHPLSPService {
    static let shared = PHPLSPService()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var readBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    private var initialized = false
    private var rootProjectPath = ""
    private var sessions: [String: LSPDocumentState] = [:]
    private var serverPathOverride = ""

    func setServerPathOverride(_ value: String) async {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != serverPathOverride else {
            return
        }

        serverPathOverride = normalized
        log("server path override changed to '\(normalized.isEmpty ? "default: phpactor" : normalized)'")
        await stopServer(sendShutdown: true)
    }

    func openOrUpdateDocument(uri: String, projectPath: String, text: String, languageID: String) async {
        guard !uri.isEmpty else { return }

        do {
            try await ensureServer(for: projectPath)
            let prepared = prepareDocumentText(text)

            if var existing = sessions[uri] {
                guard existing.sourceText != text else { return }
                existing.version += 1
                existing.sourceText = text
                existing.lspText = prepared.text
                existing.lineOffset = prepared.lineOffset
                sessions[uri] = existing
                syncScratchFile(uri: uri, text: prepared.text)
                try sendNotification(
                    method: "textDocument/didChange",
                    params: [
                        "textDocument": [
                            "uri": uri,
                            "version": existing.version
                        ],
                        "contentChanges": [
                            ["text": prepared.text]
                        ]
                    ]
                )
                return
            }

            sessions[uri] = LSPDocumentState(
                version: 1,
                sourceText: text,
                lspText: prepared.text,
                lineOffset: prepared.lineOffset
            )
            syncScratchFile(uri: uri, text: prepared.text)
            log("didOpen uri=\(uri) wrappedSnippet=\(prepared.didWrapSnippet)")
            try sendNotification(
                method: "textDocument/didOpen",
                params: [
                    "textDocument": [
                        "uri": uri,
                        "languageId": languageID,
                        "version": 1,
                        "text": prepared.text
                    ]
                ]
            )
        } catch {
            log("openOrUpdateDocument failed: \(error.localizedDescription)")
            await stopServer(sendShutdown: false)
        }
    }

    func closeDocument(uri: String) async {
        guard sessions.removeValue(forKey: uri) != nil else {
            return
        }

        log("didClose uri=\(uri)")
        do {
            try sendNotification(
                method: "textDocument/didClose",
                params: [
                    "textDocument": ["uri": uri]
                ]
            )
        } catch {
            log("closeDocument failed: \(error.localizedDescription)")
            await stopServer(sendShutdown: false)
        }
    }

    func completionItems(
        uri: String,
        projectPath: String,
        text: String,
        utf16Offset: Int,
        triggerCharacter: String?
    ) async -> [LSPCompletionCandidate] {
        guard !uri.isEmpty else {
            return []
        }

        do {
            return try await requestCompletionItems(
                uri: uri,
                projectPath: projectPath,
                text: text,
                utf16Offset: utf16Offset,
                triggerCharacter: triggerCharacter,
                timeoutSeconds: 3.0,
                resolveTopItem: true
            )
        } catch {
            if case LSPError.timeout = error {
                log("completion request timed out; retrying once")
                do {
                    return try await requestCompletionItems(
                        uri: uri,
                        projectPath: projectPath,
                        text: text,
                        utf16Offset: utf16Offset,
                        triggerCharacter: triggerCharacter,
                        timeoutSeconds: 2.0,
                        resolveTopItem: false
                    )
                } catch {
                    log("completion retry failed after timeout: \(error.localizedDescription)")
                    return []
                }
            }

            if case LSPError.disconnected = error {
                log("completion request disconnected; restarting phpactor and retrying once")
                await stopServer(sendShutdown: false)
                do {
                    return try await requestCompletionItems(
                        uri: uri,
                        projectPath: projectPath,
                        text: text,
                        utf16Offset: utf16Offset,
                        triggerCharacter: triggerCharacter,
                        timeoutSeconds: 2.5,
                        resolveTopItem: false
                    )
                } catch {
                    log("completion retry failed after reconnect: \(error.localizedDescription)")
                    return []
                }
            }

            log("completion request failed: \(error.localizedDescription)")
            return []
        }
    }

    private func requestCompletionItems(
        uri: String,
        projectPath: String,
        text: String,
        utf16Offset: Int,
        triggerCharacter: String?,
        timeoutSeconds: Double,
        resolveTopItem: Bool
    ) async throws -> [LSPCompletionCandidate] {
        try await ensureServer(for: projectPath)
        await openOrUpdateDocument(uri: uri, projectPath: projectPath, text: text, languageID: "php")

        let prepared = prepareDocumentText(text)
        let sourcePosition = LSPPositionConverter.position(in: text, utf16Offset: utf16Offset)
        let lspPosition = (line: sourcePosition.line + prepared.lineOffset, character: sourcePosition.character)
        log(
            "completion request sourceLine=\(sourcePosition.line) sourceChar=\(sourcePosition.character) " +
            "lspLine=\(lspPosition.line) lspChar=\(lspPosition.character) trigger=\(triggerCharacter ?? "manual")"
        )

        var context: [String: Any] = [
            "triggerKind": triggerCharacter == nil ? 1 : 2
        ]
        if let triggerCharacter {
            context["triggerCharacter"] = triggerCharacter
        }

        let response = try await request(
            method: "textDocument/completion",
            params: [
                "textDocument": ["uri": uri],
                "position": ["line": lspPosition.line, "character": lspPosition.character],
                "context": context
            ],
            timeoutSeconds: timeoutSeconds
        )

        var parsedItems = parseCompletionItems(from: response, lineOffset: prepared.lineOffset)
        if resolveTopItem,
           !parsedItems.isEmpty,
           parsedItems[0].candidate.documentation == nil
        {
            if let resolved = await resolveCompletionItem(parsedItems[0], lineOffset: prepared.lineOffset) {
                parsedItems[0] = resolved
            }
        }

        let parsed = parsedItems.map(\.candidate)
        let docsCount = parsed.reduce(into: 0) { partialResult, item in
            let documentation = item.documentation?.trimmingCharacters(in: .whitespacesAndNewlines)
            if documentation?.isEmpty == false {
                partialResult += 1
            }
        }
        log("completion response items=\(parsed.count) docs=\(docsCount)")
        return parsed
    }

    private func ensureServer(for projectPath: String) async throws {
        let normalized = normalizeProjectPath(projectPath)

        if process == nil || !initialized || normalized != rootProjectPath {
            try await startServer(for: normalized)
        }
    }

    private func normalizeProjectPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
        }

        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    private func startServer(for projectPath: String) async throws {
        await stopServer(sendShutdown: true)

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.currentDirectoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        if serverPathOverride.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["phpactor", "language-server"]
        } else {
            process.executableURL = URL(fileURLWithPath: serverPathOverride)
            process.arguments = ["language-server"]
        }
        log("starting phpactor cwd=\(projectPath) command=\(process.executableURL?.path() ?? "unknown") \(process.arguments?.joined(separator: " ") ?? "")")

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] _ in
            Task {
                await self?.handleProcessTermination()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeStdout(data)
            }
        }

        self.stderrHandle = stderrPipe.fileHandleForReading
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeStderr(data)
            }
        }

        do {
            try process.run()
        } catch {
            log("failed to start phpactor: \(error.localizedDescription)")
            throw LSPError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.readBuffer.removeAll(keepingCapacity: false)
        self.initialized = false
        self.rootProjectPath = projectPath
        self.sessions.removeAll(keepingCapacity: false)

        let rootURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        let rootURI = rootURL.absoluteString
        let rootName = rootURL.lastPathComponent
        let hasComposerJSON = FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("composer.json").path)
        let hasVendorDirectory = FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("vendor").path)
        log("workspace info composer.json=\(hasComposerJSON) vendor=\(hasVendorDirectory)")

        _ = try await request(
            method: "initialize",
            params: [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "rootUri": rootURI,
                "capabilities": [
                    "textDocument": [
                        "completion": [
                            "completionItem": [
                                "snippetSupport": true
                            ]
                        ]
                    ]
                ],
                "workspaceFolders": [
                    [
                        "uri": rootURI,
                        "name": rootName
                    ]
                ]
            ],
            timeoutSeconds: 8.0
        )

        try sendNotification(method: "initialized", params: [:])
        initialized = true
        log("initialize completed successfully")
    }

    private func stopServer(sendShutdown: Bool) async {
        if process != nil {
            log("stopping phpactor sendShutdown=\(sendShutdown)")
        }
        if sendShutdown, initialized {
            _ = try? await request(method: "shutdown", params: [:], timeoutSeconds: 1.0)
            try? sendNotification(method: "exit", params: [:])
        }

        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        stdinHandle = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        initialized = false
        rootProjectPath = ""
        sessions.removeAll(keepingCapacity: false)
        readBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        if !pendingRequests.isEmpty {
            let continuations = pendingRequests.values
            pendingRequests.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume(throwing: LSPError.disconnected)
            }
        }
    }

    private func handleProcessTermination() {
        log("phpactor process terminated")
        process = nil
        stdinHandle = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        initialized = false
        rootProjectPath = ""
        sessions.removeAll(keepingCapacity: false)
        readBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        if !pendingRequests.isEmpty {
            let continuations = pendingRequests.values
            pendingRequests.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume(throwing: LSPError.disconnected)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        payload["params"] = params
        try send(payload)
    }

    private func request(method: String, params: [String: Any], timeoutSeconds: Double) async throws -> JSONValue? {
        guard process != nil else {
            throw LSPError.disconnected
        }

        let id = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            do {
                try send([
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": method,
                    "params": params
                ])
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.failPendingRequest(id: id, with: LSPError.timeout)
            }
        }
    }

    private func failPendingRequest(id: Int, with error: Error) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func send(_ message: [String: Any]) throws {
        guard let stdinHandle else {
            throw LSPError.disconnected
        }

        let body = try JSONSerialization.data(withJSONObject: message, options: [])
        let header = "Content-Length: \(body.count)\r\n\r\n"

        guard let headerData = header.data(using: .utf8) else {
            throw LSPError.invalidResponse
        }

        stdinHandle.write(headerData)
        stdinHandle.write(body)
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        readBuffer.append(data)

        while true {
            guard let headerRange = readBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                return
            }

            let headerData = readBuffer.subdata(in: readBuffer.startIndex ..< headerRange.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8),
                  let contentLength = parseContentLength(from: header)
            else {
                readBuffer.removeAll(keepingCapacity: false)
                return
            }

            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + contentLength
            guard readBuffer.count >= bodyEnd else {
                return
            }

            let bodyData = readBuffer.subdata(in: bodyStart ..< bodyEnd)
            readBuffer.removeSubrange(readBuffer.startIndex ..< bodyEnd)
            handleMessage(bodyData)
        }
    }

    private func parseContentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("content-length:") {
                let value = lowercased.replacingOccurrences(of: "content-length:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private func handleMessage(_ bodyData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: bodyData, options: []),
              let message = JSONValueConverter.convert(object),
              let payload = message.objectValue
        else {
            return
        }

        guard let idValue = payload["id"] else {
            return
        }

        let requestID: Int?
        if let integer = idValue.intValue {
            requestID = integer
        } else if let stringValue = idValue.stringValue {
            requestID = Int(stringValue)
        } else {
            requestID = nil
        }

        guard let requestID,
              let continuation = pendingRequests.removeValue(forKey: requestID)
        else {
            return
        }

        if let error = payload["error"],
           let message = error["message"]?.stringValue
        {
            log("server error response: \(message)")
            continuation.resume(throwing: LSPError.serverError(message))
            return
        }

        continuation.resume(returning: payload["result"])
    }

    private func parseCompletionItems(from response: JSONValue?, lineOffset: Int) -> [LSPParsedCompletionItem] {
        guard let response else {
            return []
        }

        let rawItems: [JSONValue]
        if let object = response.objectValue,
           let items = object["items"]?.arrayValue
        {
            rawItems = items
        } else if let array = response.arrayValue {
            rawItems = array
        } else {
            return []
        }

        var parsed: [LSPParsedCompletionItem] = []
        parsed.reserveCapacity(rawItems.count)

        for value in rawItems {
            guard let object = value.objectValue else {
                continue
            }

            guard let candidate = parseCompletionCandidate(from: object, lineOffset: lineOffset) else {
                continue
            }
            parsed.append(LSPParsedCompletionItem(candidate: candidate, rawObject: object))
        }

        return parsed.sorted { lhs, rhs in
            if lhs.candidate.sortText == rhs.candidate.sortText {
                return lhs.candidate.label.localizedCaseInsensitiveCompare(rhs.candidate.label) == .orderedAscending
            }
            return lhs.candidate.sortText.localizedCaseInsensitiveCompare(rhs.candidate.sortText) == .orderedAscending
        }
    }

    private func parseCompletionCandidate(
        from object: [String: JSONValue],
        lineOffset: Int,
        id: String = UUID().uuidString,
        fallback: LSPCompletionCandidate? = nil
    ) -> LSPCompletionCandidate? {
        let fallbackLabel = fallback?.label ?? ""
        let label = object["label"]?.stringValue ?? fallbackLabel
        guard !label.isEmpty else {
            return nil
        }

        let sortText = object["sortText"]?.stringValue ?? fallback?.sortText ?? label
        let insertTextFormat = object["insertTextFormat"]?.intValue
        let rawInsertText = object["insertText"]?.stringValue ?? fallback?.insertText ?? label
        let resolvedInsertText = resolveInsertText(rawInsertText, format: insertTextFormat)

        let textEdit = parseTextEdit(object["textEdit"], lineOffset: lineOffset, format: insertTextFormat) ?? fallback?.primaryTextEdit
        let parsedAdditionalTextEdits = parseAdditionalTextEdits(object["additionalTextEdits"], lineOffset: lineOffset)
        let additionalTextEdits = parsedAdditionalTextEdits.isEmpty ? (fallback?.additionalTextEdits ?? []) : parsedAdditionalTextEdits
        let detail = object["detail"]?.stringValue
            ?? object["labelDetails"]?["detail"]?.stringValue
            ?? fallback?.detail
        let documentation = parseDocumentation(object["documentation"]) ?? fallback?.documentation
        let kind = object["kind"]?.intValue.flatMap { LSPCompletionKind(rawValue: $0) } ?? fallback?.kind

        return LSPCompletionCandidate(
            id: id,
            label: label,
            detail: detail,
            documentation: documentation,
            sortText: sortText,
            insertText: resolvedInsertText.text,
            insertSelectionRange: resolvedInsertText.selectedRange ?? fallback?.insertSelectionRange,
            primaryTextEdit: textEdit,
            additionalTextEdits: additionalTextEdits,
            kind: kind
        )
    }

    private func resolveCompletionItem(_ item: LSPParsedCompletionItem, lineOffset: Int) async -> LSPParsedCompletionItem? {
        do {
            let params = item.rawObject.mapValues(\.anyValue)
            let response = try await request(
                method: "completionItem/resolve",
                params: params,
                timeoutSeconds: 0.8
            )
            guard let resolvedObject = response?.objectValue,
                  let resolvedCandidate = parseCompletionCandidate(
                    from: resolvedObject,
                    lineOffset: lineOffset,
                    id: item.candidate.id,
                    fallback: item.candidate
                  )
            else {
                return nil
            }
            log("completionItem/resolve label=\(resolvedCandidate.label) docs=\(resolvedCandidate.documentation == nil ? 0 : 1)")
            return LSPParsedCompletionItem(candidate: resolvedCandidate, rawObject: resolvedObject)
        } catch {
            log("completionItem/resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseTextEdit(_ value: JSONValue?, lineOffset: Int, format: Int?) -> LSPTextEdit? {
        guard let value,
              let object = value.objectValue,
              let newText = object["newText"]?.stringValue
        else {
            return nil
        }

        if let range = object["range"] {
            return parseTextEdit(rangeValue: range, newText: newText, lineOffset: lineOffset, format: format)
        }

        if let insert = object["insert"] {
            return parseTextEdit(rangeValue: insert, newText: newText, lineOffset: lineOffset, format: format)
        }

        return nil
    }

    private func parseAdditionalTextEdits(_ value: JSONValue?, lineOffset: Int) -> [LSPTextEdit] {
        guard let value,
              let edits = value.arrayValue
        else {
            return []
        }

        return edits.compactMap { editValue in
            parseTextEdit(editValue, lineOffset: lineOffset, format: nil)
        }
    }

    private func parseDocumentation(_ value: JSONValue?) -> String? {
        guard let value else {
            return nil
        }

        if let string = value.stringValue {
            return sanitizeDocumentation(string)
        }

        if let object = value.objectValue,
           let markdown = object["value"]?.stringValue
        {
            return sanitizeDocumentation(markdown)
        }

        return nil
    }

    private func sanitizeDocumentation(_ value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func parseTextEdit(rangeValue: JSONValue, newText: String, lineOffset: Int, format: Int?) -> LSPTextEdit? {
        guard let rangeObject = rangeValue.objectValue,
              let start = rangeObject["start"]?.objectValue,
              let end = rangeObject["end"]?.objectValue,
              let startLine = start["line"]?.intValue,
              let startCharacter = start["character"]?.intValue,
              let endLine = end["line"]?.intValue,
              let endCharacter = end["character"]?.intValue
        else {
            return nil
        }

        let adjustedStartLine = startLine - lineOffset
        let adjustedEndLine = endLine - lineOffset
        guard adjustedStartLine >= 0, adjustedEndLine >= 0 else {
            return nil
        }
        let resolvedText = resolveInsertText(newText, format: format)

        return LSPTextEdit(
            startLine: adjustedStartLine,
            startCharacter: startCharacter,
            endLine: adjustedEndLine,
            endCharacter: endCharacter,
            newText: resolvedText.text,
            selectedRangeInNewText: resolvedText.selectedRange
        )
    }

    private func prepareDocumentText(_ sourceText: String) -> LSPPreparedDocument {
        guard shouldWrapSnippetAsPHP(sourceText) else {
            return LSPPreparedDocument(text: sourceText, lineOffset: 0, didWrapSnippet: false)
        }

        return LSPPreparedDocument(
            text: "<?php\n\(sourceText)",
            lineOffset: 1,
            didWrapSnippet: true
        )
    }

    private func shouldWrapSnippetAsPHP(_ sourceText: String) -> Bool {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(trimmed.hasPrefix("<?php") || trimmed.hasPrefix("<?"))
    }

    private func syncScratchFile(uri: String, text: String) {
        guard let fileURL = URL(string: uri), fileURL.isFileURL else {
            return
        }

        do {
            let folderURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            log("failed writing scratch file path=\(fileURL.path): \(error.localizedDescription)")
        }
    }

    private func resolveInsertText(_ value: String, format: Int?) -> LSPResolvedInsertText {
        guard format == 2 else {
            return LSPResolvedInsertText(text: value, selectedRange: nil)
        }

        return resolveSnippetInsertText(value)
    }

    private func resolveSnippetInsertText(_ snippet: String) -> LSPResolvedInsertText {
        var result = ""
        var firstSelection: NSRange?
        var finalCursorLocation: Int?
        var index = snippet.startIndex

        while index < snippet.endIndex {
            let character = snippet[index]

            if character == "\\" {
                let next = snippet.index(after: index)
                if next < snippet.endIndex {
                    result.append(snippet[next])
                    index = snippet.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "$" {
                let next = snippet.index(after: index)
                if next < snippet.endIndex, snippet[next] == "{" {
                    let contentStart = snippet.index(after: next)
                    if let closingBrace = findSnippetClosingBrace(in: snippet, from: contentStart) {
                        let content = String(snippet[contentStart..<closingBrace])
                        if let placeholder = parseSnippetPlaceholder(content) {
                            let insertLocation = (result as NSString).length
                            result.append(placeholder.text)
                            let insertLength = (placeholder.text as NSString).length

                            if placeholder.index == 0 {
                                finalCursorLocation = insertLocation + insertLength
                            } else if firstSelection == nil {
                                firstSelection = NSRange(location: insertLocation, length: insertLength)
                            }

                            index = snippet.index(after: closingBrace)
                            continue
                        }
                    }
                } else if next < snippet.endIndex, snippet[next].isNumber {
                    var digitEnd = next
                    while digitEnd < snippet.endIndex, snippet[digitEnd].isNumber {
                        digitEnd = snippet.index(after: digitEnd)
                    }

                    let indexValue = Int(snippet[next..<digitEnd]) ?? 0
                    let insertLocation = (result as NSString).length
                    if indexValue == 0 {
                        finalCursorLocation = insertLocation
                    } else if firstSelection == nil {
                        firstSelection = NSRange(location: insertLocation, length: 0)
                    }

                    index = digitEnd
                    continue
                }
            }

            result.append(character)
            index = snippet.index(after: index)
        }

        if let firstSelection {
            return LSPResolvedInsertText(text: result, selectedRange: firstSelection)
        }

        if let finalCursorLocation {
            return LSPResolvedInsertText(text: result, selectedRange: NSRange(location: finalCursorLocation, length: 0))
        }

        return LSPResolvedInsertText(text: result, selectedRange: nil)
    }

    private func parseSnippetPlaceholder(_ content: String) -> (index: Int, text: String)? {
        var indexEnd = content.startIndex
        while indexEnd < content.endIndex, content[indexEnd].isNumber {
            indexEnd = content.index(after: indexEnd)
        }

        guard indexEnd > content.startIndex else {
            return nil
        }

        guard let placeholderIndex = Int(content[..<indexEnd]) else {
            return nil
        }

        let suffix = String(content[indexEnd...])
        if suffix.isEmpty {
            return (placeholderIndex, "")
        }

        if suffix.hasPrefix(":") {
            return (placeholderIndex, unescapeSnippetText(String(suffix.dropFirst())))
        }

        if suffix.hasPrefix("|"), suffix.hasSuffix("|"), suffix.count >= 2 {
            let choicesString = String(suffix.dropFirst().dropLast())
            let firstChoice = choicesString.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return (placeholderIndex, unescapeSnippetText(firstChoice))
        }

        return nil
    }

    private func unescapeSnippetText(_ value: String) -> String {
        var output = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            if character == "\\" {
                let next = value.index(after: index)
                if next < value.endIndex {
                    output.append(value[next])
                    index = value.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            output.append(character)
            index = value.index(after: index)
        }

        return output
    }

    private func findSnippetClosingBrace(in value: String, from index: String.Index) -> String.Index? {
        var cursor = index
        while cursor < value.endIndex {
            let character = value[cursor]
            if character == "\\" {
                let escaped = value.index(after: cursor)
                cursor = escaped < value.endIndex ? value.index(after: escaped) : escaped
                continue
            }

            if character == "}" {
                return cursor
            }

            cursor = value.index(after: cursor)
        }
        return nil
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        stderrBuffer.append(data)

        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer.prefix(upTo: newlineIndex)
            stderrBuffer.removeSubrange(stderrBuffer.startIndex ... newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                log("phpactor stderr: \(trimmed)")
            }
        }
    }

    private func log(_ message: String) {
        Task { @MainActor in
            DebugConsoleStore.shared.append(stream: .app, message: "[PhpactorLSP] \(message)")
        }
    }
}
