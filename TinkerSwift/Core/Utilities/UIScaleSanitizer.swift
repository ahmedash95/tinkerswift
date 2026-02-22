import Foundation

enum UIScaleSanitizer {
    static let minScale = 0.6
    static let maxScale = 3.0
    static let defaultScale = 1.0

    private static let precisionFactor = 100.0

    static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultScale
        }

        let clamped = min(max(value, minScale), maxScale)
        let quantized = (clamped * precisionFactor).rounded(.toNearestOrAwayFromZero) / precisionFactor
        return min(max(quantized, minScale), maxScale)
    }
}
