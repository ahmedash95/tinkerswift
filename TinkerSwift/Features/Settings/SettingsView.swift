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
        .frame(width: 680, height: 520)
    }
}

// MARK: - Editor Settings

private struct EditorSettingsTab: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Appearance")
                            .font(.body)
                        Text("Choose how the app looks.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("", selection: $appModel.appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                .padding(.vertical, 2)

                Toggle(isOn: $appModel.showLineNumbers) {
                    SettingsLabel(
                        "Show Line Numbers",
                        subtitle: "Display line numbers in the editor gutter.",
                        icon: "list.number",
                        tint: .blue
                    )
                }

                Toggle(isOn: $appModel.wrapLines) {
                    SettingsLabel(
                        "Wrap Lines",
                        subtitle: "Wrap long lines to fit the visible editor width.",
                        icon: "text.word.spacing",
                        tint: .orange
                    )
                }

                Toggle(isOn: $appModel.highlightSelectedLine) {
                    SettingsLabel(
                        "Highlight Current Line",
                        subtitle: "Keep the active cursor line visually highlighted.",
                        icon: "pencil.line",
                        tint: .yellow
                    )
                }

                Toggle(isOn: $appModel.syntaxHighlighting) {
                    SettingsLabel(
                        "Syntax Highlighting",
                        subtitle: "Colorize source code by language grammar.",
                        icon: "paintbrush",
                        tint: .purple
                    )
                }
            } header: {
                Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Section {
                Toggle(isOn: $appModel.lspCompletionEnabled) {
                    SettingsLabel(
                        "LSP Completion",
                        subtitle: "Enable language-server-based completion suggestions.",
                        icon: "sparkles",
                        tint: .mint
                    )
                }

                Toggle(isOn: $appModel.lspAutoTriggerEnabled) {
                    SettingsLabel(
                        "LSP Auto Trigger",
                        subtitle: "Automatically refresh completions after typing pauses.",
                        icon: "bolt.fill",
                        tint: .cyan
                    )
                }
            } header: {
                Label("Code Intelligence", systemImage: "brain")
            }

            Section {
                Toggle(isOn: $appModel.autoFormatOnRunEnabled) {
                    SettingsLabel(
                        "Auto Format On Run",
                        subtitle: "Format code automatically each time you run.",
                        icon: "paintbrush.pointed",
                        tint: .green
                    )
                }
            } header: {
                Label("Run", systemImage: "play.fill")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Binary Settings

private struct BinarySettingsTab: View {
    @Environment(AppModel.self) private var appModel
    @State private var fallbackPaths: [AppBinaryTool: String] = [:]
    @State private var displayedPaths: [AppBinaryTool: String] = [:]

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section {
                BinaryPathRow(
                    title: AppBinaryTool.phpactor.displayName,
                    description: "Language server for PHP completion.",
                    icon: "server.rack",
                    tint: .blue,
                    path: pathBinding(tool: .phpactor, override: $appModel.lspServerPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .phpactor, override: $appModel.lspServerPathOverride)
                        }
                    }
                )

                BinaryPathRow(
                    title: AppBinaryTool.php.displayName,
                    description: "PHP runtime for code execution.",
                    icon: "chevron.left.forwardslash.chevron.right",
                    tint: .indigo,
                    path: pathBinding(tool: .php, override: $appModel.phpBinaryPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .php, override: $appModel.phpBinaryPathOverride)
                        }
                    }
                )

                BinaryPathRow(
                    title: AppBinaryTool.docker.displayName,
                    description: "Docker CLI for container projects.",
                    icon: "shippingbox",
                    tint: .cyan,
                    path: pathBinding(tool: .docker, override: $appModel.dockerBinaryPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .docker, override: $appModel.dockerBinaryPathOverride)
                        }
                    }
                )

                BinaryPathRow(
                    title: AppBinaryTool.laravel.displayName,
                    description: "Laravel installer for project templates.",
                    icon: "hammer",
                    tint: .red,
                    path: pathBinding(tool: .laravel, override: $appModel.laravelBinaryPathOverride),
                    browseAction: {
                        browseForExecutable { selectedPath in
                            updatePath(selectedPath, for: .laravel, override: $appModel.laravelBinaryPathOverride)
                        }
                    }
                )
            } header: {
                Label("Executable Paths", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
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

// MARK: - Reusable Components

private struct SettingsLabel: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    init(_ title: String, subtitle: String, icon: String, tint: Color) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BinaryPathRow: View {
    let title: String
    let description: String
    let icon: String
    let tint: Color
    @Binding var path: String
    let browseAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("", text: $path, prompt: Text("/usr/local/bin/...").foregroundStyle(.quaternary))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button(action: browseAction) {
                        Text("Browse…")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
