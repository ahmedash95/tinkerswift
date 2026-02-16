import Foundation

enum EditorColorScheme: String, CaseIterable, Identifiable {
    case `default`
    case ocean
    case solarized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .ocean: return "Ocean"
        case .solarized: return "Solarized"
        }
    }
}
