import AppKit
import SwiftUI

struct ResultPaneView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    private var presentation: ExecutionPresentation {
        workspaceState.resultPresentation
    }

    private var shouldShowPlaceholder: Bool {
        switch presentation.status {
        case .idle:
            return true
        case .empty:
            return workspaceState.resultViewMode == .pretty && !workspaceState.isRunning
        case .running, .success, .warning, .exception, .fatal, .error, .stopped:
            return false
        }
    }

    private var placeholderTitle: String {
        switch presentation.status {
        case .idle:
            return "Run code to see output"
        case .empty:
            return "Script completed with no output"
        case .running, .success, .warning, .exception, .fatal, .error, .stopped:
            return "No output"
        }
    }

    private var placeholderSubtitle: String? {
        switch presentation.status {
        case .idle:
            return "Use the Run button or Command-R."
        case .empty:
            return nil
        case .running, .success, .warning, .exception, .fatal, .error, .stopped:
            return nil
        }
    }

    private var shouldHighlightPrimarySection: Bool {
        switch presentation.status {
        case .exception, .fatal, .error:
            return true
        case .idle, .running, .success, .warning, .stopped, .empty:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspaceState.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)

                Divider()
            }

            contentBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentBody: some View {
        Group {
            if shouldShowPlaceholder {
                placeholderView
            } else {
                ScrollView(.vertical) {
                    if workspaceState.resultViewMode == .pretty {
                        prettyView
                    } else {
                        rawView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(placeholderTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let subtitle = placeholderSubtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(24)
    }

    private var prettyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(presentation.prettySections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(section.content)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(primarySectionBackground(for: index))
                )
                .overlay {
                    if shouldHighlightPrimarySection && index == 0 {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(workspaceState.resultStatusColor.opacity(0.55), lineWidth: 1)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rawView: some View {
        let output = workspaceState.rawResultText.isEmpty ? "(empty)" : workspaceState.rawResultText

        return Text(makeRawAttributedString(output))
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
    }

    private func primarySectionBackground(for index: Int) -> Color {
        if shouldHighlightPrimarySection && index == 0 {
            return workspaceState.resultStatusColor.opacity(0.08)
        }
        return .clear
    }

    private func makeRawAttributedString(_ text: String) -> AttributedString {
        let attr = NSMutableAttributedString(string: text)
        attr.addAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: 14 * workspaceState.scale, weight: .regular),
                .foregroundColor: NSColor.textColor
            ],
            range: NSRange(location: 0, length: attr.length)
        )
        return AttributedString(attr)
    }
}
