import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsTab()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }

            BinarySettingsTab()
                .tabItem {
                    Label("Binaries", systemImage: "terminal")
                }
        }
        .frame(width: 860, height: 680)
    }
}

private struct EditorSettingsTab: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section(
                header: Text("Editor"),
                footer: Text("These options control how code is rendered and navigated while you type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            ) {
                SettingsToggleRow(
                    title: "Show Line Numbers",
                    description: "Display line numbers in the editor gutter.",
                    isOn: $appModel.showLineNumbers
                )
                SettingsToggleRow(
                    title: "Wrap Lines",
                    description: "Wrap long lines to fit the visible editor width.",
                    isOn: $appModel.wrapLines
                )
                SettingsToggleRow(
                    title: "Highlight Current Line",
                    description: "Keep the active cursor line visually highlighted.",
                    isOn: $appModel.highlightSelectedLine
                )
                SettingsToggleRow(
                    title: "Syntax Highlighting",
                    description: "Colorize source code by language grammar.",
                    isOn: $appModel.syntaxHighlighting
                )
            }

            Section(
                header: Text("Code Intelligence"),
                footer: Text("Enable Language Server Protocol features such as completion and trigger behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            ) {
                SettingsToggleRow(
                    title: "LSP Completion",
                    description: "Enable language-server-based completion suggestions.",
                    isOn: $appModel.lspCompletionEnabled
                )
                SettingsToggleRow(
                    title: "LSP Auto Trigger",
                    description: "Automatically refresh completions after typing pauses.",
                    isOn: $appModel.lspAutoTriggerEnabled
                )
            }

            Section(
                header: Text("Run"),
                footer: Text("Formatting runs in background with Laravel Pint and never blocks execution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            ) {
                SettingsToggleRow(
                    title: "Auto Format On Run",
                    description: "Format code automatically each time you run.",
                    isOn: $appModel.autoFormatOnRunEnabled
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct BinarySettingsTab: View {
    @Environment(AppModel.self) private var appModel
    @State private var fallbackPaths: [AppBinaryTool: String] = [:]
    @State private var displayedPaths: [AppBinaryTool: String] = [:]

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section(
                header: Text("Executable Paths"),
                footer: Text("Set the executable path each tool should use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            ) {
                BinaryPathRow(
                    title: AppBinaryTool.phpactor.displayName,
                    description: "Language server executable used for PHP completion.",
                    path: pathBinding(tool: .phpactor, override: $appModel.lspServerPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .phpactor, override: $appModel.lspServerPathOverride)
                        }
                    }
                )

                BinaryPathRow(
                    title: AppBinaryTool.php.displayName,
                    description: "PHP runtime used for code execution and tooling.",
                    path: pathBinding(tool: .php, override: $appModel.phpBinaryPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .php, override: $appModel.phpBinaryPathOverride)
                        }
                    }
                )

                BinaryPathRow(
                    title: AppBinaryTool.docker.displayName,
                    description: "Docker CLI used for container project support.",
                    path: pathBinding(tool: .docker, override: $appModel.dockerBinaryPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .docker, override: $appModel.dockerBinaryPathOverride)
                        }
                    }
                )

                BinaryPathRow(
                    title: AppBinaryTool.laravel.displayName,
                    description: "Laravel installer used by project templates.",
                    path: pathBinding(tool: .laravel, override: $appModel.laravelBinaryPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .laravel, override: $appModel.laravelBinaryPathOverride)
                        }
                    }
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            await loadInitialPaths()
        }
    }

    private func pathBinding(tool: AppBinaryTool, override: Binding<String>) -> Binding<String> {
        Binding(
            get: {
                displayedPaths[tool] ?? resolvedPath(for: tool, override: override.wrappedValue)
            },
            set: { newValue in
                updatePath(newValue, for: tool, override: override)
            }
        )
    }

    private func updatePath(_ newValue: String, for tool: AppBinaryTool, override: Binding<String>) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            override.wrappedValue = ""
            displayedPaths[tool] = fallbackPaths[tool] ?? ""
            return
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        override.wrappedValue = trimmed
        displayedPaths[tool] = expanded
    }

    private func resolvedPath(for tool: AppBinaryTool, override: String) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return (trimmed as NSString).expandingTildeInPath
        }
        return fallbackPaths[tool] ?? ""
    }

    private func loadInitialPaths() async {
        let fallback = await Task.detached(priority: .userInitiated) {
            var values: [AppBinaryTool: String] = [:]
            for tool in AppBinaryTool.allCases {
                values[tool] = BinaryPathResolver.detectedDefaultPath(for: tool) ?? ""
            }
            return values
        }.value

        fallbackPaths = fallback
        displayedPaths[.phpactor] = resolvedPath(for: .phpactor, override: appModel.lspServerPathOverride)
        displayedPaths[.php] = resolvedPath(for: .php, override: appModel.phpBinaryPathOverride)
        displayedPaths[.docker] = resolvedPath(for: .docker, override: appModel.dockerBinaryPathOverride)
        displayedPaths[.laravel] = resolvedPath(for: .laravel, override: appModel.laravelBinaryPathOverride)
    }

    private func browseForExecutable(onSelect: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Executable"
        panel.prompt = "Use Path"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

private struct BinaryPathRow: View {
    let title: String
    let description: String
    @Binding var path: String
    let browseAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                TextField("", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
                    .multilineTextAlignment(.leading)

                Button(action: browseAction) {
                    Text("Browse")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .frame(maxWidth: 470, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
