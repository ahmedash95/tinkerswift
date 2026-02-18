import Foundation

@MainActor
final class LanguagePluginRegistry {
    private var pluginsByID: [String: any LanguagePlugin] = [:]
    private var pluginOrder: [String] = []

    func register(_ plugin: any LanguagePlugin) {
        if pluginsByID[plugin.id] == nil {
            pluginOrder.append(plugin.id)
        }
        pluginsByID[plugin.id] = plugin
    }

    func plugin(id: String) -> (any LanguagePlugin)? {
        pluginsByID[id]
    }

    func plugin(forLanguageID languageID: String) -> (any LanguagePlugin)? {
        for id in pluginOrder {
            guard let plugin = pluginsByID[id] else { continue }
            if plugin.supportedLanguageIDs.contains(languageID) {
                return plugin
            }
        }
        return nil
    }

    var allPlugins: [any LanguagePlugin] {
        pluginOrder.compactMap { pluginsByID[$0] }
    }
}
