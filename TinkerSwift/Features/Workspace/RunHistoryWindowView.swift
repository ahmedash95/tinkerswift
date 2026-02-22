import Foundation
import SwiftUI

struct RunHistoryWindowView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        NavigationSplitView {
            List(selection: $workspaceState.selectedRunHistoryItemID) {
                if workspaceState.selectedProjectRunHistory.isEmpty {
                    Text("No runs yet for this project")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspaceState.selectedProjectRunHistory) { item in
                        RunHistoryRowView(item: item)
                            .tag(item.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            if let selectedRunHistoryItem = workspaceState.selectedRunHistoryItem {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.dateFormatter.string(from: selectedRunHistoryItem.executedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    AppKitCodeEditor(
                        text: previewCodeBinding(for: selectedRunHistoryItem),
                        fontSize: 13 * workspaceState.scale,
                        showLineNumbers: true,
                        wrapLines: false,
                        highlightSelectedLine: false,
                        syntaxHighlighting: workspaceState.syntaxHighlighting,
                        isEditable: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Spacer()
                        Button("Use") {
                            workspaceState.useSelectedRunHistoryItem()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            } else {
                ContentUnavailableView("No Run Selected", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle("Run History")
        .navigationSubtitle(workspaceState.selectedProjectName)
        .onAppear {
            workspaceState.selectRunHistoryItemIfNeeded()
        }
        .onChange(of: workspaceState.selectedProjectID) { _, _ in
            workspaceState.selectRunHistoryItemIfNeeded()
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func previewCodeBinding(for item: ProjectRunHistoryItem) -> Binding<String> {
        Binding(
            get: { item.code },
            set: { _ in }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct RunHistoryRowView: View {
    let item: ProjectRunHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.codePreview(for: item.code))
                .lineLimit(1)
                .font(.system(.body, design: .monospaced))
            Text(Self.dateFormatter.string(from: item.executedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private static func codePreview(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(empty snippet)" }
        return trimmed.components(separatedBy: .newlines).first ?? "(empty snippet)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
