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
    let lspLanguageID: String
    let completionProvider: (any CompletionProviding)?

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
        lspServerPathOverride: String = "",
        lspLanguageID: String = "php",
        completionProvider: (any CompletionProviding)? = PHPLSPService.shared
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
        self.lspLanguageID = lspLanguageID
        self.completionProvider = completionProvider
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            provider: completionProvider ?? NoopCompletionProvider.shared,
            languageID: lspLanguageID
        )
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
            enabled: isEditable && lspCompletionEnabled && completionProvider != nil,
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
            enabled: isEditable && lspCompletionEnabled && completionProvider != nil,
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

        private let completionOrchestrator: EditorCompletionOrchestrator
        private var completionPopupFontSize: CGFloat = 12
        private let completionViewController = ScaledCompletionViewController()

        init(text: Binding<String>, provider: any CompletionProviding, languageID: String) {
            _text = text
            completionOrchestrator = EditorCompletionOrchestrator(
                provider: provider,
                languageID: languageID,
                logger: { message in
                    DebugConsoleStore.shared.append(stream: .app, message: "[EditorCompletion] \(message)")
                }
            )
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
            completionOrchestrator.configure(
                projectPath: projectPath,
                enabled: enabled,
                autoTriggerEnabled: autoTriggerEnabled,
                serverPathOverride: serverPathOverride,
                currentText: currentText
            )
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
            completionOrchestrator.handleTextMutation(
                replacementString: replacementString,
                fullText: textView.text ?? ""
            ) {
                DispatchQueue.main.async {
                    textView.complete(nil)
                }
            }
        }

        func textView(_ textView: STTextView, completionItemsAtLocation location: any NSTextLocation) async -> [any STCompletionItem]? {
            let fullText = textView.text ?? ""
            let documentStart = textView.textLayoutManager.documentRange.location
            let utf16Offset = textView.textLayoutManager.offset(from: documentStart, to: location)
            let completionItems = await completionOrchestrator.completionItems(
                fullText: fullText,
                utf16Offset: utf16Offset
            )
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

            logEditor(
                "insert completion label='\(completionItem.candidate.label)' additionalEdits=\(completionItem.candidate.additionalTextEdits.count)"
            )
            insertCompletion(completionItem.candidate, into: textView)
            completionOrchestrator.didInsertCompletion(finalText: textView.text ?? "")
        }

        func scheduleDocumentSync(text: String, immediate: Bool = false) {
            completionOrchestrator.syncDocument(text: text, immediate: immediate)
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

private actor NoopCompletionProvider: CompletionProviding {
    static let shared = NoopCompletionProvider()
    let languageID = "php"

    func setServerPathOverride(_ value: String) async {}

    func openOrUpdateDocument(uri: String, projectPath: String, text: String, languageID: String) async {}

    func closeDocument(uri: String) async {}

    func completionItems(
        uri: String,
        projectPath: String,
        text: String,
        utf16Offset: Int,
        triggerCharacter: String?
    ) async -> [CompletionCandidate] {
        []
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
        center.removeObserver(self, name: .tinkerSwiftInsertTextAtCursor, object: nil)

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
        center.addObserver(
            self,
            selector: #selector(handleInsertTextNotification(_:)),
            name: .tinkerSwiftInsertTextAtCursor,
            object: nil
        )
    }

    @objc
    private func handleVisualStateNotification(_ notification: Notification) {
        notifyVisualStateChanged()
    }

    @objc
    private func handleInsertTextNotification(_ notification: Notification) {
        guard isEditable else { return }
        guard let payload = notification.userInfo?["text"] as? String else { return }
        guard !payload.isEmpty else { return }

        let selectedRange = selectedRange()
        let replacementRange: NSRange
        if selectedRange.location == NSNotFound {
            let currentText = text ?? ""
            let length = (currentText as NSString).length
            replacementRange = NSRange(location: length, length: 0)
        } else {
            replacementRange = selectedRange
        }

        replaceCharacters(in: replacementRange, with: payload)
        let insertedLength = (payload as NSString).length
        textSelection = NSRange(location: replacementRange.location + insertedLength, length: 0)
    }

    private func notifyVisualStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onVisualStateChange?()
        }
    }
}

typealias LSPTextEdit = CompletionTextEdit

private struct LSPResolvedInsertText: Sendable {
    let text: String
    let selectedRange: NSRange?
}

private enum LSPPositionConverter {
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

typealias LSPCompletionCandidate = CompletionCandidate

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
                systemSymbolName: candidate.kind?.symbolName ?? CompletionItemKind.defaultSymbolName,
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

private extension CompletionItemKind {
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
