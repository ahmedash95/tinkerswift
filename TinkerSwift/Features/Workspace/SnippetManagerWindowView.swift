import SwiftUI

struct SnippetManagerWindowView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        @Bindable var workspaceState = workspaceState

        NavigationSplitView {
            VStack(spacing: 10) {
                TextField("Search snippets", text: $workspaceState.snippetManagerSearchText)
                    .textFieldStyle(.roundedBorder)

                List(selection: $workspaceState.selectedSnippetID) {
                    if workspaceState.filteredSnippets.isEmpty {
                        Text("No snippets found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceState.filteredSnippets) { snippet in
                            SnippetRowView(
                                snippet: snippet,
                                sourceProjectName: workspaceState.sourceProjectDisplayName(for: snippet)
                            )
                            .tag(snippet.id)
                        }
                    }
                }
            }
            .padding(12)
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            if let selectedSnippet = workspaceState.selectedSnippet {
                SnippetDetailPane(snippet: selectedSnippet)
                    .environment(workspaceState)
                    .padding(12)
            } else {
                ContentUnavailableView("No Snippet Selected", systemImage: "text.badge.plus")
            }
        }
        .navigationTitle("Snippets")
        .navigationSubtitle("All Projects")
        .navigationSplitViewStyle(.balanced)
        .alert("Delete Snippet?", isPresented: deleteAlertPresented, presenting: workspaceState.snippetDeleteCandidate) { _ in
            Button("Delete", role: .destructive) {
                workspaceState.deleteSnippetCandidate()
            }
            Button("Cancel", role: .cancel) {
                workspaceState.snippetDeleteCandidate = nil
            }
        } message: { snippet in
            Text("Delete \"\(snippet.title)\" permanently?")
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { workspaceState.snippetDeleteCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    workspaceState.snippetDeleteCandidate = nil
                }
            }
        )
    }
}

private struct SnippetDetailPane: View {
    @Environment(WorkspaceState.self) private var workspaceState
    let snippet: WorkspaceSnippetItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if workspaceState.editingSnippetID == snippet.id {
                editForm
            } else {
                readOnlyView
            }
        }
    }

    private var readOnlyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snippet.title)
                .font(.title3.weight(.semibold))

            Text("Source: \(workspaceState.sourceProjectDisplayName(for: snippet))")
                .font(.caption)
                .foregroundStyle(.secondary)

            AppKitCodeEditor(
                text: previewBinding(for: snippet),
                fontSize: 13 * workspaceState.scale,
                showLineNumbers: true,
                wrapLines: true,
                highlightSelectedLine: false,
                syntaxHighlighting: workspaceState.syntaxHighlighting,
                isEditable: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Insert at Cursor") {
                    workspaceState.insertSelectedSnippetAtCursor()
                }
                Button("Replace Editor") {
                    workspaceState.replaceEditorWithSelectedSnippet()
                }
                Spacer()
                Button("Edit") {
                    workspaceState.beginEditingSelectedSnippet()
                }
                Button("Delete", role: .destructive) {
                    workspaceState.requestDeleteSelectedSnippet()
                }
            }
        }
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Snippet")
                .font(.title3.weight(.semibold))

            Text("Source: \(workspaceState.sourceProjectDisplayName(for: snippet))")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                "Title",
                text: Binding(
                    get: { workspaceState.editingSnippetTitle },
                    set: { workspaceState.editingSnippetTitle = $0 }
                )
            )
                .textFieldStyle(.roundedBorder)

            AppKitCodeEditor(
                text: Binding(
                    get: { workspaceState.editingSnippetContent },
                    set: { workspaceState.editingSnippetContent = $0 }
                ),
                fontSize: 13 * workspaceState.scale,
                showLineNumbers: true,
                wrapLines: true,
                highlightSelectedLine: true,
                syntaxHighlighting: workspaceState.syntaxHighlighting
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel") {
                    workspaceState.cancelSnippetEditing()
                }
                Button("Save") {
                    workspaceState.saveSnippetEditing()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!workspaceState.canSaveSnippetEdit)
            }
        }
    }

    private func previewBinding(for snippet: WorkspaceSnippetItem) -> Binding<String> {
        Binding(
            get: { snippet.content },
            set: { _ in }
        )
    }
}

private struct SnippetRowView: View {
    let snippet: WorkspaceSnippetItem
    let sourceProjectName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snippet.title)
                .lineLimit(1)
                .font(.body.weight(.medium))

            Text(sourceProjectName)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(Self.dateFormatter.string(from: snippet.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

struct SnippetCaptureSheet: View {
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var workspaceState = workspaceState

        VStack(alignment: .leading, spacing: 12) {
            Text("Save Snippet")
                .font(.title3.weight(.semibold))

            Text("Capture current editor content as a reusable snippet.")
                .foregroundStyle(.secondary)

            TextField("Title", text: $workspaceState.snippetDraftTitle)
                .textFieldStyle(.roundedBorder)

            Text("Source Project: \(workspaceState.snippetDraftSourceProjectName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            AppKitCodeEditor(
                text: $workspaceState.snippetDraftContent,
                fontSize: 13 * workspaceState.scale,
                showLineNumbers: true,
                wrapLines: true,
                highlightSelectedLine: true,
                syntaxHighlighting: workspaceState.syntaxHighlighting
            )
            .frame(minHeight: 220)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel") {
                    workspaceState.cancelSnippetDraft()
                    dismiss()
                }
                Button("Save Snippet") {
                    workspaceState.saveSnippetFromDraft()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!workspaceState.canSaveSnippetDraft)
            }
        }
        .padding(18)
        .frame(width: 760, height: 520)
    }
}
