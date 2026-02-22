import Foundation

enum TextPositionConverter {
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
