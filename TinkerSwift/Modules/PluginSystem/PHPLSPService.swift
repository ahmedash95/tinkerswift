import Foundation

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

private struct LSPResolvedInsertText: Sendable {
    let text: String
    let selectedRange: NSRange?
}

private struct LSPParsedCompletionItem: Sendable {
    let candidate: CompletionCandidate
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

actor PHPLSPService: CompletionProviding {
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
    let languageID = "php"

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
    ) async -> [CompletionCandidate] {
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
    ) async throws -> [CompletionCandidate] {
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

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.currentDirectoryURL = projectURL
        process.environment = BinaryPathResolver.processEnvironment()

        guard BinaryPathResolver.effectivePath(for: .php) != nil else {
            throw LSPError.launchFailed("PHP binary not found in PATH. Configure PATH or install php.")
        }

        if let resolvedPhpactorPath = resolvedPhpactorPath() {
            process.executableURL = URL(fileURLWithPath: resolvedPhpactorPath)
            process.arguments = ["language-server"]
        } else {
            throw LSPError.launchFailed("Phpactor binary not found in PATH. Configure path override in Settings > Binaries.")
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

        let rootURL = projectURL
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

    private func resolvedPhpactorPath() -> String? {
        let override = serverPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
            return nil
        }
        return BinaryPathResolver.effectivePath(for: .phpactor)
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
        fallback: CompletionCandidate? = nil
    ) -> CompletionCandidate? {
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
        let kind = object["kind"]?.intValue.flatMap { CompletionItemKind(rawValue: $0) } ?? fallback?.kind

        return CompletionCandidate(
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

    private func parseTextEdit(_ value: JSONValue?, lineOffset: Int, format: Int?) -> CompletionTextEdit? {
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

    private func parseAdditionalTextEdits(_ value: JSONValue?, lineOffset: Int) -> [CompletionTextEdit] {
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

    private func parseTextEdit(rangeValue: JSONValue, newText: String, lineOffset: Int, format: Int?) -> CompletionTextEdit? {
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

        return CompletionTextEdit(
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
