import SwiftUI
import UniformTypeIdentifiers
import STTextView
import STPluginNeon

private struct LaravelProject: Codable, Hashable, Identifiable {
    let path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

private struct RunMetrics {
    let durationMs: Double
    let peakMemoryBytes: UInt64
}

struct ContentView: View {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    @AppStorage("app.uiScale") private var appUIScale = 1.0
    @AppStorage("editor.showLineNumbers") private var showLineNumbers = true
    @AppStorage("editor.wrapLines") private var wrapLines = true
    @AppStorage("editor.highlightSelectedLine") private var highlightSelectedLine = true
    @AppStorage("editor.syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("editor.colorScheme") private var editorColorSchemeRaw = EditorColorScheme.default.rawValue
    @AppStorage("laravel.projectPath") private var laravelProjectPath = ""
    @AppStorage("laravel.projectsJSON") private var laravelProjectsJSON = "[]"
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isPickingProjectFolder = false
    @State private var isRunning = false
    @State private var lastRunMetrics: RunMetrics?
    @State private var projects: [LaravelProject] = []
    @State private var code = """
use App\\Models\\User;

$users = User::query()
    ->latest()
    ->take(5)
    ->get(['id', 'name', 'email']);

return $users->toJson();
"""
    @State private var result = "Press Run to execute code."

    private var scale: CGFloat {
        CGFloat(max(0.6, min(appUIScale, 3.0)))
    }
    
    private var selectedProjectName: String {
        guard !laravelProjectPath.isEmpty else { return "No project selected" }
        if let project = projects.first(where: { $0.path == laravelProjectPath }) {
            return project.name
        }
        return URL(fileURLWithPath: laravelProjectPath).lastPathComponent
    }

    private var editorColorScheme: EditorColorScheme {
        EditorColorScheme(rawValue: editorColorSchemeRaw) ?? .default
    }

    private var executionTimeText: String {
        if isRunning {
            return "Running"
        }
        guard let metrics = lastRunMetrics else {
            return "--"
        }
        return formatDuration(metrics.durationMs)
    }

    private var memoryUsageText: String {
        if isRunning {
            return "--"
        }
        guard let metrics = lastRunMetrics else {
            return "--"
        }
        return formatMemory(metrics.peakMemoryBytes)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                List(selection: $laravelProjectPath) {
                    Section("Projects") {
                        if projects.isEmpty {
                            Text("No projects added")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(projects) { project in
                                Label(project.name, systemImage: "folder")
                                    .tag(project.path)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button(action: { isPickingProjectFolder = true }) {
                        Label("Add Project", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            ReplWorkspace(
                code: $code,
                result: result,
                isRunning: isRunning,
                selectedProjectName: selectedProjectName,
                selectedProjectPath: laravelProjectPath,
                contentScale: scale,
                showLineNumbers: showLineNumbers,
                wrapLines: wrapLines,
                highlightSelectedLine: highlightSelectedLine,
                syntaxHighlighting: syntaxHighlighting,
                colorScheme: editorColorScheme,
                executionTimeText: executionTimeText,
                memoryUsageText: memoryUsageText,
                runAction: runCodeTapped
            )
        }
        .frame(minWidth: 1000, minHeight: 620)
        .onAppear {
            loadProjects()
        }
        .fileImporter(
            isPresented: $isPickingProjectFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            addProject(url.path())
        }
        .focusedSceneValue(\.runCodeAction, runCodeTapped)
    }

    private func runCodeTapped() {
        guard !isRunning else { return }
        Task {
            await runCode()
        }
    }

    private func runCode() async {
        guard !laravelProjectPath.isEmpty else {
            result = "Select a Laravel project folder first (toolbar: plus.folder)."
            return
        }

        isRunning = true
        defer { isRunning = false }

        let execution = await PHPExecutionService.run(code: code, projectPath: laravelProjectPath)
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let durationMs = execution.durationMs,
           let peakMemoryBytes = execution.peakMemoryBytes {
            lastRunMetrics = RunMetrics(durationMs: durationMs, peakMemoryBytes: peakMemoryBytes)
        } else {
            lastRunMetrics = nil
        }

        if !stdout.isEmpty {
            result = execution.stdout
        } else if !stderr.isEmpty {
            result = execution.stderr
        } else if execution.exitCode != 0 {
            result = "Process failed with exit code \(execution.exitCode)."
        } else {
            result = "(empty)"
        }
    }

    private func loadProjects() {
        projects = decodeProjects(from: laravelProjectsJSON)
        if !laravelProjectPath.isEmpty, !projects.contains(where: { $0.path == laravelProjectPath }) {
            addProject(laravelProjectPath)
            return
        }
        if laravelProjectPath.isEmpty, let first = projects.first {
            laravelProjectPath = first.path
        }
    }

    private func addProject(_ path: String) {
        let normalizedPath = normalizeProjectPath(path)
        var updated = projects
        if !updated.contains(where: { $0.path == normalizedPath }) {
            updated.append(LaravelProject(path: normalizedPath))
            updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        projects = updated
        laravelProjectPath = normalizedPath
        persistProjects(updated)
    }

    private func persistProjects(_ projects: [LaravelProject]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projects),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        laravelProjectsJSON = json
    }

    private func decodeProjects(from json: String) -> [LaravelProject] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LaravelProject].self, from: data) else {
            return []
        }
        // Keep order stable and deduplicate by path.
        var seen = Set<String>()
        return decoded.compactMap { project in
            let normalizedPath = normalizeProjectPath(project.path)
            guard !normalizedPath.isEmpty else { return nil }
            guard seen.insert(normalizedPath).inserted else { return nil }
            return LaravelProject(path: normalizedPath)
        }
    }

    private func normalizeProjectPath(_ raw: String) -> String {
        var normalized = URL(fileURLWithPath: raw).standardizedFileURL.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func formatDuration(_ durationMs: Double) -> String {
        if durationMs < 1000 {
            return String(format: "%.0f ms", durationMs)
        }
        return String(format: "%.2f s", durationMs / 1000)
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        ContentView.memoryFormatter.string(fromByteCount: Int64(bytes))
    }
}

private struct ReplWorkspace: View {
    @Binding var code: String
    let result: String
    let isRunning: Bool
    let selectedProjectName: String
    let selectedProjectPath: String
    let contentScale: CGFloat
    let showLineNumbers: Bool
    let wrapLines: Bool
    let highlightSelectedLine: Bool
    let syntaxHighlighting: Bool
    let colorScheme: EditorColorScheme
    let executionTimeText: String
    let memoryUsageText: String
    let runAction: () -> Void

    var body: some View {
        HSplitView {
            EditorPane(
                code: $code,
                projectPath: selectedProjectPath,
                contentScale: contentScale,
                showLineNumbers: showLineNumbers,
                wrapLines: wrapLines,
                highlightSelectedLine: highlightSelectedLine,
                syntaxHighlighting: syntaxHighlighting,
                colorScheme: colorScheme
            )
                .frame(minWidth: 320, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)

            ResultPane(result: result, isRunning: isRunning, contentScale: contentScale)
                .frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: runAction) {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(isRunning)
            }

            ToolbarItemGroup(placement: .primaryAction) {
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: isRunning ? "hourglass" : "timer")
                            Text(executionTimeText)
                                .font(.callout.monospacedDigit())
                        }
                        .frame(minWidth: 92, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Execution time")

                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "memorychip")
                            Text(memoryUsageText)
                                .font(.callout.monospacedDigit())
                        }
                        .frame(minWidth: 110, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Peak memory usage")
                }
            }
        }
        .navigationTitle(selectedProjectName)
        .navigationSubtitle(selectedProjectPath.isEmpty ? "No project selected" : selectedProjectPath)
    }
}

private struct EditorPane: View {
    @Binding var code: String
    let projectPath: String
    let contentScale: CGFloat
    let showLineNumbers: Bool
    let wrapLines: Bool
    let highlightSelectedLine: Bool
    let syntaxHighlighting: Bool
    let colorScheme: EditorColorScheme

    var body: some View {
        AppKitCodeEditor(
            text: $code,
            fontSize: 14 * contentScale,
            showLineNumbers: showLineNumbers,
            wrapLines: wrapLines,
            highlightSelectedLine: highlightSelectedLine,
            syntaxHighlighting: syntaxHighlighting,
            colorScheme: colorScheme
        )
            .id("editor-\(showLineNumbers)-\(wrapLines)-\(highlightSelectedLine)-\(syntaxHighlighting)-\(colorScheme.rawValue)-\(projectPath)")
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ResultPane: View {
    let result: String
    let isRunning: Bool
    let contentScale: CGFloat
    
    private var formattedResult: AttributedString {
        ResultFormatter.format(result, fontSize: 14 * contentScale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical) {
                Text(formattedResult)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private enum ResultFormatter {
    static func format(_ raw: String, fontSize: CGFloat) -> AttributedString {
        let text = raw.isEmpty ? "(empty)" : raw
        if let json = prettyPrintedJSON(from: text) {
            return highlightJSON(json, fontSize: fontSize)
        }
        return plain(text, fontSize: fontSize)
    }

    private static func prettyPrintedJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return pretty
    }

    private static func plain(_ text: String, fontSize: CGFloat) -> AttributedString {
        let attr = NSMutableAttributedString(string: text)
        attr.addAttributes(baseAttributes(fontSize: fontSize), range: NSRange(location: 0, length: attr.length))
        return AttributedString(attr)
    }

    private static func highlightJSON(_ json: String, fontSize: CGFloat) -> AttributedString {
        let attr = NSMutableAttributedString(string: json)
        let fullRange = NSRange(location: 0, length: attr.length)
        attr.addAttributes(baseAttributes(fontSize: fontSize), range: fullRange)

        apply(pattern: #"\"(?:\\.|[^\"\\])*\""#, color: .systemGreen, to: attr) // strings
        apply(pattern: #"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, to: attr) // numbers
        apply(pattern: #"\b(?:true|false|null)\b"#, color: .systemPurple, to: attr) // bool/null
        apply(pattern: #"[{}\[\]:,]"#, color: .secondaryLabelColor, to: attr) // punctuation
        apply(pattern: #"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: .systemBlue, to: attr) // keys override

        return AttributedString(attr)
    }

    private static func apply(pattern: String, color: NSColor, to attr: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(location: 0, length: attr.length)
        regex.matches(in: attr.string, options: [], range: range).forEach { match in
            attr.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }
}

private struct AppKitCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let showLineNumbers: Bool
    let wrapLines: Bool
    let highlightSelectedLine: Bool
    let syntaxHighlighting: Bool
    let colorScheme: EditorColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView

        textView.textDelegate = context.coordinator
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.highlightSelectedLine = highlightSelectedLine
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        textView.text = text

        textView.gutterView?.textColor = .secondaryLabelColor
        textView.gutterView?.drawSeparator = true

        context.coordinator.applyEditorFont(fontSize, to: textView, force: true)
        context.coordinator.installPlugins(on: textView, syntaxHighlighting: syntaxHighlighting, colorScheme: colorScheme)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else {
            return
        }

        if (textView.text ?? "") != text {
            context.coordinator.isSyncing = true
            textView.text = text
            context.coordinator.isSyncing = false
        }

        textView.highlightSelectedLine = highlightSelectedLine
        textView.showsLineNumbers = showLineNumbers
        textView.isHorizontallyResizable = !wrapLines
        context.coordinator.applyEditorFont(fontSize, to: textView)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.gutterView?.textColor = .secondaryLabelColor
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        @Binding var text: String
        var isSyncing = false
        private var lastAppliedFontSize: CGFloat = 0
        private var didInstallPlugin = false

        init(text: Binding<String>) {
            self._text = text
        }

        func installPlugins(on textView: STTextView, syntaxHighlighting: Bool, colorScheme: EditorColorScheme) {
            guard syntaxHighlighting, !didInstallPlugin else { return }
            let colorOnlyTheme = makeColorOnlyTheme(colorScheme)
            textView.addPlugin(NeonPlugin(theme: colorOnlyTheme, language: .php))
            didInstallPlugin = true
        }

        private func makeColorOnlyTheme(_ scheme: EditorColorScheme) -> Theme {
            switch scheme {
            case .default:
                return Theme(colors: Theme.default.colors, fonts: Theme.Fonts(fonts: [:]))
            case .ocean:
                return Theme(colors: Theme.Colors(colors: [
                    "plain": NSColor(hex: "#DDEAF7"),
                    "boolean": NSColor(hex: "#78DCE8"),
                    "comment": NSColor(hex: "#6B8BAA"),
                    "constructor": NSColor(hex: "#A6E22E"),
                    "function.call": NSColor(hex: "#A6E22E"),
                    "include": NSColor(hex: "#F78C6C"),
                    "keyword": NSColor(hex: "#C792EA"),
                    "keyword.function": NSColor(hex: "#C792EA"),
                    "keyword.return": NSColor(hex: "#C792EA"),
                    "method": NSColor(hex: "#82AAFF"),
                    "number": NSColor(hex: "#F78C6C"),
                    "operator": NSColor(hex: "#89DDFF"),
                    "parameter": NSColor(hex: "#FFCB6B"),
                    "punctuation.special": NSColor(hex: "#89DDFF"),
                    "string": NSColor(hex: "#C3E88D"),
                    "text.literal": NSColor(hex: "#C3E88D"),
                    "text.title": NSColor(hex: "#82AAFF"),
                    "type": NSColor(hex: "#FFCB6B"),
                    "variable.builtin": NSColor(hex: "#FF5370"),
                    "variable": NSColor(hex: "#DDEAF7")
                ]), fonts: Theme.Fonts(fonts: [:]))
            case .solarized:
                return Theme(colors: Theme.Colors(colors: [
                    "plain": NSColor(hex: "#839496"),
                    "boolean": NSColor(hex: "#2AA198"),
                    "comment": NSColor(hex: "#586E75"),
                    "constructor": NSColor(hex: "#B58900"),
                    "function.call": NSColor(hex: "#268BD2"),
                    "include": NSColor(hex: "#CB4B16"),
                    "keyword": NSColor(hex: "#859900"),
                    "keyword.function": NSColor(hex: "#859900"),
                    "keyword.return": NSColor(hex: "#859900"),
                    "method": NSColor(hex: "#268BD2"),
                    "number": NSColor(hex: "#D33682"),
                    "operator": NSColor(hex: "#6C71C4"),
                    "parameter": NSColor(hex: "#B58900"),
                    "punctuation.special": NSColor(hex: "#6C71C4"),
                    "string": NSColor(hex: "#2AA198"),
                    "text.literal": NSColor(hex: "#2AA198"),
                    "text.title": NSColor(hex: "#268BD2"),
                    "type": NSColor(hex: "#B58900"),
                    "variable.builtin": NSColor(hex: "#CB4B16"),
                    "variable": NSColor(hex: "#839496")
                ]), fonts: Theme.Fonts(fonts: [:]))
            }
        }

        func applyEditorFont(_ size: CGFloat, to textView: STTextView, force: Bool = false) {
            guard force || abs(lastAppliedFontSize - size) > 0.001 else { return }
            lastAppliedFontSize = size

            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            textView.font = font

            let length = (textView.text ?? "").utf16.count
            if length > 0 {
                textView.addAttributes([.font: font], range: NSRange(location: 0, length: length))
            }

            textView.gutterView?.font = font
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isSyncing, let textView = notification.object as? STTextView else {
                return
            }

            text = textView.text ?? ""
        }
    }
}

#Preview {
    ContentView()
}

private extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
