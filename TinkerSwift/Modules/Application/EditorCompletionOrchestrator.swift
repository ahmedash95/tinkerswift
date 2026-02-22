import Foundation

@MainActor
final class EditorCompletionOrchestrator {
    private let provider: any CompletionProviding
    private let languageID: String
    private let logger: (String) -> Void

    private var enabled = false
    private var autoTriggerEnabled = true
    private var currentProjectPath = ""
    private var currentDocumentURI = ""
    private var serverPathOverride = ""
    private var pendingDocumentSyncTask: Task<Void, Never>?
    private var pendingDebouncedCompletionTask: Task<Void, Never>?
    private var pendingTriggerCharacter: String?
    private var latestCompletionRequestToken: UInt64 = 0
    private var lastConfigurationSignature = ""

    init(provider: any CompletionProviding, languageID: String, logger: @escaping (String) -> Void) {
        self.provider = provider
        self.languageID = languageID
        self.logger = logger
    }

    deinit {
        pendingDocumentSyncTask?.cancel()
        pendingDebouncedCompletionTask?.cancel()

        if enabled, !currentDocumentURI.isEmpty {
            let uri = currentDocumentURI
            let provider = self.provider
            Task {
                await provider.closeDocument(uri: uri)
            }
        }
    }

    func configure(
        projectPath: String,
        enabled: Bool,
        autoTriggerEnabled: Bool,
        serverPathOverride: String,
        currentText: String
    ) {
        let normalizedProjectPath = normalizedProjectPath(projectPath)
        let newDocumentURI = documentURI(forProjectPath: normalizedProjectPath)
        let previousDocumentURI = currentDocumentURI
        let wasEnabled = self.enabled

        if self.serverPathOverride != serverPathOverride {
            self.serverPathOverride = serverPathOverride
            Task {
                await provider.setServerPathOverride(serverPathOverride)
            }
        }

        self.autoTriggerEnabled = autoTriggerEnabled
        self.enabled = enabled
        self.currentProjectPath = normalizedProjectPath
        self.currentDocumentURI = newDocumentURI

        let signature = "\(enabled)|\(autoTriggerEnabled)|\(normalizedProjectPath)|\(newDocumentURI)|\(serverPathOverride)"
        if signature != lastConfigurationSignature {
            lastConfigurationSignature = signature
            logger("configure lsp enabled=\(enabled) autoTrigger=\(autoTriggerEnabled) project=\(normalizedProjectPath)")
        }

        if wasEnabled,
           !previousDocumentURI.isEmpty,
           (previousDocumentURI != newDocumentURI || !enabled)
        {
            Task {
                await provider.closeDocument(uri: previousDocumentURI)
            }
        }

        if enabled {
            scheduleDocumentSync(text: currentText, immediate: true)
        } else {
            pendingDocumentSyncTask?.cancel()
            pendingDebouncedCompletionTask?.cancel()
        }
    }

    func textDidChange(fullText: String) {
        guard enabled else { return }
        scheduleDocumentSync(text: fullText)
    }

    func syncDocument(text: String, immediate: Bool = false) {
        scheduleDocumentSync(text: text, immediate: immediate)
    }

    func handleTextMutation(replacementString: String, fullText: String, requestCompletion: @escaping () -> Void) {
        guard enabled else { return }
        scheduleDocumentSync(text: fullText)

        guard autoTriggerEnabled else {
            pendingDebouncedCompletionTask?.cancel()
            return
        }

        if let triggerCharacter = triggerCharacter(from: replacementString) {
            pendingDebouncedCompletionTask?.cancel()
            pendingTriggerCharacter = triggerCharacter
            logger("auto-trigger completion char='\(triggerCharacter)'")
            requestCompletion()
            return
        }

        guard shouldDebounceCompletion(from: replacementString) else {
            pendingDebouncedCompletionTask?.cancel()
            return
        }

        pendingDebouncedCompletionTask?.cancel()
        pendingDebouncedCompletionTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, self.enabled, self.autoTriggerEnabled else { return }
            self.pendingTriggerCharacter = nil
            self.logger("auto-refresh completion (debounced)")
            requestCompletion()
        }
    }

    func completionItems(fullText: String, utf16Offset: Int) async -> [CompletionCandidate] {
        guard enabled, !currentDocumentURI.isEmpty else {
            return []
        }

        latestCompletionRequestToken &+= 1
        let requestToken = latestCompletionRequestToken

        let triggerCharacter = pendingTriggerCharacter
        pendingTriggerCharacter = nil

        let position = TextPositionConverter.position(in: fullText, utf16Offset: utf16Offset)
        logger("request completion line=\(position.line) char=\(position.character) trigger=\(triggerCharacter ?? "manual")")

        let completionItems = await provider.completionItems(
            uri: currentDocumentURI,
            projectPath: currentProjectPath,
            text: fullText,
            utf16Offset: utf16Offset,
            triggerCharacter: triggerCharacter
        )

        guard requestToken == latestCompletionRequestToken else {
            logger("discard stale completion response token=\(requestToken)")
            return []
        }

        logger("completion response count=\(completionItems.count)")
        return completionItems
    }

    func didInsertCompletion(finalText: String) {
        pendingDebouncedCompletionTask?.cancel()
        scheduleDocumentSync(text: finalText, immediate: true)
    }

    private func scheduleDocumentSync(text: String, immediate: Bool = false) {
        guard enabled, !currentDocumentURI.isEmpty else {
            return
        }

        pendingDocumentSyncTask?.cancel()

        let uri = currentDocumentURI
        let projectPath = currentProjectPath
        let languageID = languageID
        pendingDocumentSyncTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }

            guard !Task.isCancelled else { return }

            await provider.openOrUpdateDocument(
                uri: uri,
                projectPath: projectPath,
                text: text,
                languageID: languageID
            )
        }
    }

    private func normalizedProjectPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
        }

        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    private func documentURI(forProjectPath projectPath: String) -> String {
        URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent(".tinkerswift_scratch.php")
            .standardizedFileURL
            .absoluteString
    }

    private func triggerCharacter(from replacementString: String) -> String? {
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

    private func shouldDebounceCompletion(from replacementString: String) -> Bool {
        if replacementString.isEmpty {
            return true
        }

        guard replacementString.count == 1 else {
            return false
        }

        let value = (replacementString as NSString).character(at: 0)
        return isTokenCharacter(value) || value == 92
    }

    private func isTokenCharacter(_ value: unichar) -> Bool {
        if value == 95 || value == 36 {
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

}
