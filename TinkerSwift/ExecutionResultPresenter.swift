import AppKit
import Foundation

enum ExecutionPresentationStatus {
    case idle
    case running
    case success
    case warning
    case exception
    case fatal
    case error
    case stopped
    case empty
}

struct ExecutionPresentationSection: Identifiable {
    let id = UUID()
    let title: String
    let content: AttributedString
}

struct ExecutionPresentation {
    let status: ExecutionPresentationStatus
    let title: String
    let subtitle: String?
    let prettySections: [ExecutionPresentationSection]
    let rawStdout: String
    let rawStderr: String
    let hasStdout: Bool
    let hasStderr: Bool
}

enum ExecutionResultPresenter {
    private struct ParsedException {
        let className: String
        let message: String
        let thrownLocation: String
        let stackFrames: [String]
        let rawText: String
        let isFatal: Bool
    }

    private static let warningRegex = try! NSRegularExpression(
        pattern: #"(?im)^(?:PHP\s+)?(?:Warning|Notice|Deprecated|User Warning|User Notice|User Deprecated)\b.*$"#,
        options: []
    )

    private static let fatalRegex = try! NSRegularExpression(
        pattern: #"(?im)\b(?:PHP\s+)?(?:Fatal error|Parse error|Uncaught Error|Uncaught TypeError)\b"#,
        options: []
    )

    private static let uncaughtExceptionRegex = try! NSRegularExpression(
        pattern: #"(?s)(?:PHP\s+Fatal\s+error:\s+)?Uncaught\s+([A-Za-z_\\][A-Za-z0-9_\\]*)\s*:\s*(.*?)\s+in\s+(.+?)\s+on\s+line\s+(\d+)(.*)$"#,
        options: []
    )

    private static let genericExceptionRegex = try! NSRegularExpression(
        pattern: #"(?s)^([A-Za-z_\\][A-Za-z0-9_\\]*)\s*:\s*(.*?)\s+in\s+(.+?):(\d+)(.*)$"#,
        options: []
    )

    static func present(
        execution: PHPExecutionResult?,
        statusMessage: String,
        isRunning: Bool,
        fontSize: CGFloat
    ) -> ExecutionPresentation {
        if isRunning {
            return ExecutionPresentation(
                status: .running,
                title: "Running",
                subtitle: statusMessage,
                prettySections: [
                    section(title: "Status", text: statusMessage, color: .secondaryLabelColor, fontSize: fontSize)
                ],
                rawStdout: "",
                rawStderr: "",
                hasStdout: false,
                hasStderr: false
            )
        }

        guard let execution else {
            return ExecutionPresentation(
                status: .idle,
                title: "Ready",
                subtitle: nil,
                prettySections: [
                    section(title: "Status", text: statusMessage, color: .secondaryLabelColor, fontSize: fontSize)
                ],
                rawStdout: "",
                rawStderr: "",
                hasStdout: false,
                hasStderr: false
            )
        }

        let stdout = execution.stdout
        let stderr = execution.stderr
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStdout = !trimmedStdout.isEmpty
        let hasStderr = !trimmedStderr.isEmpty

        if execution.wasStopped {
            var sections: [ExecutionPresentationSection] = [
                section(title: "Status", text: "Execution stopped.", color: .secondaryLabelColor, fontSize: fontSize)
            ]
            if hasStderr {
                sections.append(section(title: "Error Output", text: trimmedStderr, color: .systemRed, fontSize: fontSize))
            }
            if hasStdout {
                sections.append(section(title: "Output", text: trimmedStdout, color: .textColor, fontSize: fontSize))
            }

            return ExecutionPresentation(
                status: .stopped,
                title: "Stopped",
                subtitle: nil,
                prettySections: sections,
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: hasStdout,
                hasStderr: hasStderr
            )
        }

        let warningLines = extractWarningLines(from: [trimmedStderr, trimmedStdout])
        if let parsedException = parseException(from: trimmedStderr) ?? parseException(from: trimmedStdout) {
            var sections: [ExecutionPresentationSection] = [
                section(title: "Exception", text: parsedException.className, color: .systemRed, fontSize: fontSize),
                section(title: "Message", text: parsedException.message, color: .textColor, fontSize: fontSize),
                section(title: "Thrown At", text: parsedException.thrownLocation, color: .secondaryLabelColor, fontSize: fontSize)
            ]

            if !parsedException.stackFrames.isEmpty {
                sections.append(
                    section(
                        title: "Stack Trace",
                        text: parsedException.stackFrames.joined(separator: "\n"),
                        color: .textColor,
                        fontSize: fontSize
                    )
                )
            }

            if !warningLines.isEmpty {
                sections.append(section(title: "Warnings", text: warningLines.joined(separator: "\n"), color: .systemOrange, fontSize: fontSize))
            }

            if hasStdout && parsedException.rawText != trimmedStdout {
                sections.append(section(title: "Output", text: trimmedStdout, color: .textColor, fontSize: fontSize))
            }

            if hasStderr && parsedException.rawText != trimmedStderr {
                sections.append(section(title: "Error Output", text: trimmedStderr, color: .systemRed, fontSize: fontSize))
            }

            return ExecutionPresentation(
                status: parsedException.isFatal ? .fatal : .exception,
                title: parsedException.isFatal ? "Fatal Exception" : "Exception",
                subtitle: nil,
                prettySections: sections,
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: hasStdout,
                hasStderr: hasStderr
            )
        }

        let hasFatal = containsFatal(in: trimmedStderr) || containsFatal(in: trimmedStdout)
        if hasFatal {
            var sections: [ExecutionPresentationSection] = []
            if hasStderr {
                sections.append(section(title: "Fatal Error", text: trimmedStderr, color: .systemRed, fontSize: fontSize))
            } else if hasStdout {
                sections.append(section(title: "Fatal Error", text: trimmedStdout, color: .systemRed, fontSize: fontSize))
            }
            if hasStdout && hasStderr {
                sections.append(section(title: "Output", text: trimmedStdout, color: .textColor, fontSize: fontSize))
            }

            return ExecutionPresentation(
                status: .fatal,
                title: "Fatal Error",
                subtitle: nil,
                prettySections: sections,
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: hasStdout,
                hasStderr: hasStderr
            )
        }

        if !warningLines.isEmpty {
            var sections: [ExecutionPresentationSection] = [
                section(title: "Warnings", text: warningLines.joined(separator: "\n"), color: .systemOrange, fontSize: fontSize)
            ]
            if hasStdout {
                sections.append(section(title: "Output", text: trimmedStdout, color: .textColor, fontSize: fontSize))
            }
            if hasStderr {
                sections.append(section(title: "Error Output", text: trimmedStderr, color: .systemOrange, fontSize: fontSize))
            }

            return ExecutionPresentation(
                status: .warning,
                title: "Warnings",
                subtitle: nil,
                prettySections: sections,
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: hasStdout,
                hasStderr: hasStderr
            )
        }

        if hasStdout, !hasStderr, let prettyJSON = prettyPrintedJSON(from: trimmedStdout) {
            return ExecutionPresentation(
                status: .success,
                title: "JSON Output",
                subtitle: nil,
                prettySections: [
                    jsonSection(title: "Output", json: prettyJSON, fontSize: fontSize)
                ],
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: hasStdout,
                hasStderr: hasStderr
            )
        }

        if execution.exitCode != 0 {
            var sections: [ExecutionPresentationSection] = []
            if hasStderr {
                sections.append(section(title: "Error", text: trimmedStderr, color: .systemRed, fontSize: fontSize))
            }
            if hasStdout {
                sections.append(section(title: "Output", text: trimmedStdout, color: .textColor, fontSize: fontSize))
            }
            if sections.isEmpty {
                sections.append(section(title: "Error", text: "Process failed with exit code \(execution.exitCode).", color: .systemRed, fontSize: fontSize))
            }

            return ExecutionPresentation(
                status: .error,
                title: "Execution Failed",
                subtitle: "Exit code \(execution.exitCode)",
                prettySections: sections,
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: hasStdout,
                hasStderr: hasStderr
            )
        }

        if !hasStdout && !hasStderr {
            return ExecutionPresentation(
                status: .empty,
                title: "No Output",
                subtitle: nil,
                prettySections: [
                    section(title: "Output", text: "(empty)", color: .secondaryLabelColor, fontSize: fontSize)
                ],
                rawStdout: stdout,
                rawStderr: stderr,
                hasStdout: false,
                hasStderr: false
            )
        }

        var sections: [ExecutionPresentationSection] = []
        if hasStdout {
            sections.append(section(title: "Output", text: trimmedStdout, color: .textColor, fontSize: fontSize))
        }
        if hasStderr {
            sections.append(section(title: "Error Output", text: trimmedStderr, color: .systemRed, fontSize: fontSize))
        }

        return ExecutionPresentation(
            status: .success,
            title: "Success",
            subtitle: nil,
            prettySections: sections,
            rawStdout: stdout,
            rawStderr: stderr,
            hasStdout: hasStdout,
            hasStderr: hasStderr
        )
    }

    private static func extractWarningLines(from texts: [String]) -> [String] {
        var lines: [String] = []
        for text in texts where !text.isEmpty {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            warningRegex.matches(in: text, options: [], range: range).forEach { match in
                let line = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
        }
        return Array(NSOrderedSet(array: lines)) as? [String] ?? lines
    }

    private static func parseException(from text: String) -> ParsedException? {
        guard !text.isEmpty else { return nil }

        if let parsed = parseException(using: uncaughtExceptionRegex, in: text, isFatal: true) {
            return parsed
        }
        if let parsed = parseException(using: genericExceptionRegex, in: text, isFatal: containsFatal(in: text)) {
            return parsed
        }
        return nil
    }

    private static func parseException(
        using regex: NSRegularExpression,
        in text: String,
        isFatal: Bool
    ) -> ParsedException? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        let className = capture(match, group: 1, in: nsText).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = capture(match, group: 2, in: nsText).trimmingCharacters(in: .whitespacesAndNewlines)
        let file = capture(match, group: 3, in: nsText).trimmingCharacters(in: .whitespacesAndNewlines)
        let line = capture(match, group: 4, in: nsText).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = capture(match, group: 5, in: nsText)
        let thrownLocation = line.isEmpty ? file : "\(file):\(line)"

        let stackFrames = parseStackFrames(from: tail)
        return ParsedException(
            className: className.isEmpty ? "Exception" : className,
            message: message.isEmpty ? "(no message)" : message,
            thrownLocation: thrownLocation,
            stackFrames: stackFrames,
            rawText: text,
            isFatal: isFatal
        )
    }

    private static func parseStackFrames(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: .newlines)
        var frames: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#") else { continue }

            if let frame = parseStructuredStackFrame(line) {
                frames.append(frame)
            } else {
                frames.append(line)
            }
        }
        return frames
    }

    private static func parseStructuredStackFrame(_ line: String) -> String? {
        let pattern = #"^#(\d+)\s+(.+?)\((\d+)\):\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        let index = capture(match, group: 1, in: nsLine)
        let file = capture(match, group: 2, in: nsLine)
        let lineNumber = capture(match, group: 3, in: nsLine)
        let call = capture(match, group: 4, in: nsLine)
        return "#\(index) \(call)\n   \(file):\(lineNumber)"
    }

    private static func containsFatal(in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return fatalRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func prettyPrintedJSON(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return pretty
    }

    private static func section(title: String, text: String, color: NSColor, fontSize: CGFloat) -> ExecutionPresentationSection {
        let attr = NSMutableAttributedString(string: text)
        attr.addAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: color
            ],
            range: NSRange(location: 0, length: attr.length)
        )
        return ExecutionPresentationSection(title: title, content: AttributedString(attr))
    }

    private static func jsonSection(title: String, json: String, fontSize: CGFloat) -> ExecutionPresentationSection {
        let attr = NSMutableAttributedString(string: json)
        let fullRange = NSRange(location: 0, length: attr.length)
        attr.addAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ],
            range: fullRange
        )

        apply(pattern: #"\"(?:\\.|[^\"\\])*\""#, color: .systemGreen, to: attr)
        apply(pattern: #"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, to: attr)
        apply(pattern: #"\b(?:true|false|null)\b"#, color: .systemPurple, to: attr)
        apply(pattern: #"[{}\[\]:,]"#, color: .secondaryLabelColor, to: attr)
        apply(pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: .systemBlue, to: attr)

        return ExecutionPresentationSection(title: title, content: AttributedString(attr))
    }

    private static func apply(pattern: String, color: NSColor, to attr: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(location: 0, length: attr.length)
        regex.matches(in: attr.string, options: [], range: range).forEach { match in
            attr.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func capture(_ match: NSTextCheckingResult, group: Int, in text: NSString) -> String {
        guard group < match.numberOfRanges else { return "" }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return "" }
        return text.substring(with: range)
    }
}
