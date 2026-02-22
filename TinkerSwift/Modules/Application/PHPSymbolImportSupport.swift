import Foundation

enum PHPSymbolImportSupport {
    static func inferFullyQualifiedSymbolName(name: String, detail: String?) -> String? {
        let normalizedName = sanitizeSymbolName(name)
        guard !normalizedName.isEmpty else { return nil }
        if normalizedName.contains("\\") {
            return normalizedName
        }

        guard let detail else { return nil }
        let normalizedDetail = sanitizeSymbolName(detail)
        guard normalizedDetail.contains("\\") else { return nil }
        if normalizedDetail.hasSuffix("\\\(normalizedName)") {
            return normalizedDetail
        }
        return "\(normalizedDetail)\\\(normalizedName)"
    }

    static func sanitizeSymbolName(_ value: String) -> String {
        var result = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "class ", with: "")
            .replacingOccurrences(of: "interface ", with: "")
            .replacingOccurrences(of: "trait ", with: "")
            .replacingOccurrences(of: "enum ", with: "")
        while result.hasPrefix("\\") {
            result.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bestFQCNMatch(in source: String, shortName: String) -> String? {
        let candidates = extractFQCNCandidates(from: source)
        guard !candidates.isEmpty else {
            return nil
        }

        for candidate in candidates {
            if candidate.split(separator: "\\").last.map(String.init) == shortName {
                return candidate
            }
        }

        return candidates.first
    }

    static func extractFQCNCandidates(from source: String) -> [String] {
        let pattern = #"\\?[A-Za-z_][A-Za-z0-9_]*(?:\\[A-Za-z_][A-Za-z0-9_]*)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(location: 0, length: (source as NSString).length)
        let matches = regex.matches(in: source, options: [], range: range)
        var results: [String] = []
        results.reserveCapacity(matches.count)
        for match in matches {
            let raw = (source as NSString).substring(with: match.range)
            let normalized = sanitizeSymbolName(raw)
            if normalized.contains("\\") {
                results.append(normalized)
            }
        }
        return results
    }

    static func makeImportTextEdit(fqcn: String, in sourceText: String) -> CompletionTextEdit? {
        let normalized = sanitizeSymbolName(fqcn)
        guard normalized.contains("\\") else {
            return nil
        }

        let lines = sourceText.components(separatedBy: "\n")
        guard let plan = importInsertionPlan(for: normalized, in: lines) else {
            return nil
        }

        var newText = "use \(normalized);\n"
        if plan.needsTrailingBlankLine {
            newText += "\n"
        }

        return CompletionTextEdit(
            startLine: plan.index,
            startCharacter: 0,
            endLine: plan.index,
            endCharacter: 0,
            newText: newText,
            selectedRangeInNewText: nil
        )
    }

    static func insertingUseStatement(fqcn: String, into sourceText: String) -> String? {
        let normalized = sanitizeSymbolName(fqcn)
        guard normalized.contains("\\") else {
            return nil
        }

        var lines = sourceText.components(separatedBy: "\n")
        guard let plan = importInsertionPlan(for: normalized, in: lines) else {
            return nil
        }

        lines.insert("use \(normalized);", at: plan.index)
        if plan.needsTrailingBlankLine {
            lines.insert("", at: plan.index + 1)
        }
        return lines.joined(separator: "\n")
    }

    private struct ImportInsertionPlan {
        let index: Int
        let needsTrailingBlankLine: Bool
    }

    private static func importInsertionPlan(for normalizedFQCN: String, in lines: [String]) -> ImportInsertionPlan? {
        let escapedFQCN = NSRegularExpression.escapedPattern(for: normalizedFQCN)
        let existingPattern = #"^\s*use\s+\\?"# + escapedFQCN + #"\s*;\s*$"#
        if lines.contains(where: { $0.range(of: existingPattern, options: .regularExpression) != nil }) {
            return nil
        }

        let namespaceName = currentNamespace(in: lines)
        if let namespaceName, normalizedFQCN.hasPrefix(namespaceName + "\\") {
            return nil
        }

        var insertIndex = 0
        if let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<?php") {
            insertIndex = 1
        }

        while insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertIndex += 1
        }

        if insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("declare(") {
            insertIndex += 1
            while insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertIndex += 1
            }
        }

        if insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("namespace ") {
            insertIndex += 1
            while insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertIndex += 1
            }
        }

        while insertIndex < lines.count && lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("use ") {
            insertIndex += 1
        }

        let needsTrailingBlankLine = insertIndex < lines.count && !lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ImportInsertionPlan(index: insertIndex, needsTrailingBlankLine: needsTrailingBlankLine)
    }

    private static func currentNamespace(in lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("namespace ") else { continue }
            let namespace = trimmed
                .replacingOccurrences(of: "namespace ", with: "")
                .replacingOccurrences(of: ";", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = sanitizeSymbolName(namespace)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }
}
