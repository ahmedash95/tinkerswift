import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case php
    case laravel
    case phpactor
    case docker
    case defaultProject

    var title: String {
        switch self {
        case .php: return "PHP Runtime"
        case .laravel: return "Laravel Installer"
        case .phpactor: return "Phpactor"
        case .docker: return "Docker"
        case .defaultProject: return "Default Laravel Project"
        }
    }

    var description: String {
        switch self {
        case .php:
            return "Required to execute snippets."
        case .laravel:
            return "Required to scaffold the built-in Default project."
        case .phpactor:
            return "Optional. Enables completion and symbol navigation."
        case .docker:
            return "Optional. Enables Docker-based project execution."
        case .defaultProject:
            return "Install Default Laravel project to finish setup."
        }
    }

    var binaryTool: AppBinaryTool? {
        switch self {
        case .php: return .php
        case .laravel: return .laravel
        case .phpactor: return .phpactor
        case .docker: return .docker
        case .defaultProject: return nil
        }
    }
}

struct OnboardingSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(WorkspaceState.self) private var workspaceState

    @Binding var isPresented: Bool

    @State private var step: OnboardingStep = .php
    @State private var detectedBinaryPaths: [AppBinaryTool: String?] = [:]
    @State private var pathInputs: [AppBinaryTool: String] = [:]
    @State private var didSkipPhpactor = false
    @State private var didSkipDocker = false

    private var allSteps: [OnboardingStep] { OnboardingStep.allCases }
    private var stepIndex: Int { allSteps.firstIndex(of: step) ?? 0 }

    private var canMoveNext: Bool {
        switch step {
        case .php:
            return resolvedPath(for: .php) != nil
        case .laravel:
            return resolvedPath(for: .laravel) != nil
        case .phpactor:
            return resolvedPath(for: .phpactor) != nil || didSkipPhpactor
        case .docker:
            return resolvedPath(for: .docker) != nil || didSkipDocker
        case .defaultProject:
            return workspaceState.isDefaultLaravelProjectInstalled
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let tool = step.binaryTool {
                            binaryStep(for: tool)
                        } else {
                            defaultProjectStep
                        }
                    }
                    .padding(28)
                }

                Divider()
                footer
            }
        }
        .frame(width: 930, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshBinaryChecks(preserveInputs: false)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(allSteps.enumerated()), id: \.offset) { index, item in
                StepRowView(
                    number: index + 1,
                    title: item.title,
                    isCurrent: item == step,
                    isComplete: isStepComplete(item)
                )
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 250, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.system(size: 29, weight: .semibold, design: .rounded))

                Spacer()

                Text("Step \(stepIndex + 1) of \(allSteps.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                    )
            }

            Text(step.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            if stepIndex > 0 {
                Button("Back") {
                    moveToPreviousStep()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()

            if step == .defaultProject {
                Button("Finish") {
                    finishOnboarding()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canMoveNext)
            } else {
                Button("Next") {
                    moveToNextStep()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canMoveNext)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func binaryStep(for tool: AppBinaryTool) -> some View {
        let currentPath = resolvedPath(for: tool)
        let required = (tool == .php || tool == .laravel)

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(required ? "Executable Path (Required)" : "Executable Path (Optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField(
                        "/path/to/\(tool.rawValue)",
                        text: binaryPathBinding(for: tool)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button("Browse") {
                        browseForExecutable(tool: tool)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Text(statusText(for: tool))
                .font(.caption)
                .foregroundStyle(statusColor(for: tool, required: required))

            HStack(spacing: 10) {
                Button("Re-check") {
                    refreshBinaryChecks(preserveInputs: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let autoDetected = detectedBinaryPaths[tool] ?? nil, !autoDetected.isEmpty {
                    Button("Use Auto Detect") {
                        pathInputs[tool] = autoDetected
                        persistPathInput(for: tool)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if tool == .phpactor, currentPath == nil, !didSkipPhpactor {
                    Button("Skip For Now") {
                        didSkipPhpactor = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if tool == .docker, currentPath == nil, !didSkipDocker {
                    Button("Skip For Now") {
                        didSkipDocker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()
            }

            if let autoDetected = detectedBinaryPaths[tool] ?? nil,
               !autoDetected.isEmpty,
               autoDetected != pathInputs[tool] {
                Text("Auto-detected: \(autoDetected)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if tool == .phpactor, didSkipPhpactor {
                Text("Phpactor skipped. You can configure it later in Settings > Binaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tool == .docker, didSkipDocker {
                Text("Docker skipped. You can configure it later in Settings > Binaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var defaultProjectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workspaceState.isDefaultLaravelProjectInstalled ? "Default Laravel project is ready." : "Install the Default Laravel project.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Install Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField(
                    "laravel new Default --database=sqlite --no-interaction --force",
                    text: Binding(
                        get: { workspaceState.defaultProjectInstallCommand },
                        set: { workspaceState.defaultProjectInstallCommand = $0 }
                    ),
                    axis: .vertical
                )
                .font(.system(.body, design: .monospaced))
                .lineLimit(2 ... 4)
                .textFieldStyle(.roundedBorder)
                .disabled(workspaceState.isInstallingDefaultProject || workspaceState.isDefaultLaravelProjectInstalled)
            }

            HStack {
                Button {
                    workspaceState.installDefaultProject()
                } label: {
                    if workspaceState.isInstallingDefaultProject {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Install Default Project")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspaceState.isInstallingDefaultProject || workspaceState.isDefaultLaravelProjectInstalled)

                Spacer()
            }

            if !workspaceState.defaultProjectInstallErrorMessage.isEmpty {
                Text(workspaceState.defaultProjectInstallErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
            }

            if !workspaceState.defaultProjectInstallOutput.isEmpty {
                ScrollView {
                    Text(workspaceState.defaultProjectInstallOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 240)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func statusText(for tool: AppBinaryTool) -> String {
        if resolvedPath(for: tool) != nil {
            return "Executable path is valid."
        }
        if tool == .phpactor, didSkipPhpactor {
            return "Skipped for now."
        }
        if tool == .docker, didSkipDocker {
            return "Skipped for now."
        }
        return "Executable not found."
    }

    private func statusColor(for tool: AppBinaryTool, required: Bool) -> Color {
        if resolvedPath(for: tool) != nil { return .secondary }
        if tool == .phpactor, didSkipPhpactor { return .secondary }
        if tool == .docker, didSkipDocker { return .secondary }
        return required ? .red : .secondary
    }

    private func moveToNextStep() {
        guard stepIndex + 1 < allSteps.count else { return }
        step = allSteps[stepIndex + 1]
    }

    private func moveToPreviousStep() {
        guard stepIndex > 0 else { return }
        step = allSteps[stepIndex - 1]
    }

    private func refreshBinaryChecks(preserveInputs: Bool) {
        var next: [AppBinaryTool: String?] = [:]
        for tool in AppBinaryTool.allCases {
            next[tool] = BinaryPathResolver.detectedDefaultPath(for: tool)
        }
        detectedBinaryPaths = next

        for tool in AppBinaryTool.allCases {
            let currentInput = pathInputs[tool]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if preserveInputs, !currentInput.isEmpty {
                continue
            }

            let override = overridePath(for: tool).trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty {
                pathInputs[tool] = (override as NSString).expandingTildeInPath
                continue
            }

            if let detected = next[tool] ?? nil {
                pathInputs[tool] = detected
            } else {
                pathInputs[tool] = ""
            }
        }
    }

    private func resolvedPath(for tool: AppBinaryTool) -> String? {
        let input = pathInputs[tool]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !input.isEmpty {
            let expanded = (input as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        guard let detected = detectedBinaryPaths[tool] ?? nil else { return nil }
        return FileManager.default.isExecutableFile(atPath: detected) ? detected : nil
    }

    private func overridePath(for tool: AppBinaryTool) -> String {
        switch tool {
        case .phpactor: return appModel.lspServerPathOverride
        case .php: return appModel.phpBinaryPathOverride
        case .docker: return appModel.dockerBinaryPathOverride
        case .laravel: return appModel.laravelBinaryPathOverride
        }
    }

    private func setOverridePath(_ value: String, for tool: AppBinaryTool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case .phpactor:
            appModel.lspServerPathOverride = trimmed
        case .php:
            appModel.phpBinaryPathOverride = trimmed
        case .docker:
            appModel.dockerBinaryPathOverride = trimmed
        case .laravel:
            appModel.laravelBinaryPathOverride = trimmed
        }
    }

    private func binaryPathBinding(for tool: AppBinaryTool) -> Binding<String> {
        Binding(
            get: { pathInputs[tool] ?? "" },
            set: { newValue in
                pathInputs[tool] = newValue
                persistPathInput(for: tool)
                if tool == .phpactor, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    didSkipPhpactor = false
                }
                if tool == .docker, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    didSkipDocker = false
                }
            }
        )
    }

    private func persistPathInput(for tool: AppBinaryTool) {
        let input = pathInputs[tool]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if input.isEmpty {
            setOverridePath("", for: tool)
            return
        }

        let expanded = (input as NSString).expandingTildeInPath
        if let detected = detectedBinaryPaths[tool] ?? nil, detected == expanded {
            setOverridePath("", for: tool)
        } else {
            setOverridePath(input, for: tool)
        }
    }

    private func browseForExecutable(tool: AppBinaryTool) {
        let panel = NSOpenPanel()
        panel.title = "Choose Executable"
        panel.prompt = "Use Path"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            pathInputs[tool] = url.path
            persistPathInput(for: tool)
            if tool == .phpactor {
                didSkipPhpactor = false
            }
            if tool == .docker {
                didSkipDocker = false
            }
        }
    }

    private func isStepComplete(_ item: OnboardingStep) -> Bool {
        switch item {
        case .php:
            return resolvedPath(for: .php) != nil
        case .laravel:
            return resolvedPath(for: .laravel) != nil
        case .phpactor:
            return resolvedPath(for: .phpactor) != nil || didSkipPhpactor
        case .docker:
            return resolvedPath(for: .docker) != nil || didSkipDocker
        case .defaultProject:
            return workspaceState.isDefaultLaravelProjectInstalled
        }
    }

    private func finishOnboarding() {
        appModel.hasCompletedOnboarding = true
        workspaceState.isShowingDefaultProjectInstallSheet = false
        isPresented = false
    }
}

private struct StepRowView: View {
    let number: Int
    let title: String
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isCurrent ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: 1
                    )
                    .background(
                        Circle()
                            .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }

            Text(title)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent || isComplete ? Color.primary : Color.secondary)

            Spacer(minLength: 0)

            if isComplete {
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }
}
