import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

enum DebugConsoleStream: String, CaseIterable, Identifiable {
    case stdout = "STDOUT"
    case stderr = "STDERR"
    case app = "APP"

    var id: String { rawValue }
}

struct DebugConsoleEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let stream: DebugConsoleStream
    let message: String

    @MainActor
    var formattedTimestamp: String {
        DebugConsoleFormatting.shared.timeFormatter.string(from: timestamp)
    }
}

@MainActor
@Observable
final class DebugConsoleStore {
    static let shared = DebugConsoleStore()

    private(set) var entries: [DebugConsoleEntry] = []

    var maxEntries = 5_000

    func append(stream: DebugConsoleStream, message: String, date: Date = Date()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.append(DebugConsoleEntry(timestamp: date, stream: stream, message: trimmed))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    func exportText(entries: [DebugConsoleEntry]? = nil) -> String {
        let source = entries ?? self.entries
        return source
            .map { "[\($0.formattedTimestamp)] [\($0.stream.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}

@MainActor
final class DebugConsoleWindowManager {
    static let shared = DebugConsoleWindowManager()

    private var windowController: NSWindowController?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = DebugConsoleView()
            .environment(DebugConsoleStore.shared)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "Debug Console"
        window.setContentSize(NSSize(width: 900, height: 460))
        window.minSize = NSSize(width: 640, height: 320)
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windowController = controller

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowController = nil
                if let closeObserver = self.closeObserver {
                    NotificationCenter.default.removeObserver(closeObserver)
                    self.closeObserver = nil
                }
            }
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

actor DebugConsoleCaptureService {
    static let shared = DebugConsoleCaptureService()

    private var started = false

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutReadHandle: FileHandle?
    private var stderrReadHandle: FileHandle?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    private var originalStdoutFD: Int32 = -1
    private var originalStderrFD: Int32 = -1

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        originalStdoutFD = dup(STDOUT_FILENO)
        originalStderrFD = dup(STDERR_FILENO)

        let outPipe = Pipe()
        let errPipe = Pipe()

        stdoutPipe = outPipe
        stderrPipe = errPipe

        stdoutReadHandle = outPipe.fileHandleForReading
        stderrReadHandle = errPipe.fileHandleForReading

        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        stdoutReadHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task {
                await self.handleIncoming(data: data, stream: .stdout)
            }
        }

        stderrReadHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task {
                await self.handleIncoming(data: data, stream: .stderr)
            }
        }

        Task { @MainActor in
            DebugConsoleStore.shared.append(stream: .app, message: "Debug console capture started")
        }
    }

    func stop() {
        guard started else { return }
        started = false

        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil

        stdoutReadHandle = nil
        stderrReadHandle = nil

        stdoutPipe = nil
        stderrPipe = nil

        if originalStdoutFD >= 0 {
            dup2(originalStdoutFD, STDOUT_FILENO)
            close(originalStdoutFD)
            originalStdoutFD = -1
        }

        if originalStderrFD >= 0 {
            dup2(originalStderrFD, STDERR_FILENO)
            close(originalStderrFD)
            originalStderrFD = -1
        }

        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
    }

    private func handleIncoming(data: Data, stream: DebugConsoleStream) {
        guard !data.isEmpty else { return }

        mirrorToOriginal(data: data, stream: stream)

        switch stream {
        case .stdout:
            process(data: data, buffer: &stdoutBuffer, stream: .stdout)
        case .stderr:
            process(data: data, buffer: &stderrBuffer, stream: .stderr)
        case .app:
            break
        }
    }

    private func mirrorToOriginal(data: Data, stream: DebugConsoleStream) {
        let destinationFD: Int32
        switch stream {
        case .stdout:
            destinationFD = originalStdoutFD
        case .stderr:
            destinationFD = originalStderrFD
        case .app:
            destinationFD = -1
        }

        guard destinationFD >= 0 else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = write(destinationFD, baseAddress, rawBuffer.count)
        }
    }

    private func process(data: Data, buffer: inout Data, stream: DebugConsoleStream) {
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(buffer.startIndex ... newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }

            Task { @MainActor in
                DebugConsoleStore.shared.append(stream: stream, message: line)
            }
        }

        let maxPartialBytes = 8_192
        if buffer.count > maxPartialBytes {
            if let line = String(data: buffer, encoding: .utf8) {
                Task { @MainActor in
                    DebugConsoleStore.shared.append(stream: stream, message: line)
                }
            }
            buffer.removeAll(keepingCapacity: false)
        }
    }
}

private enum DebugConsoleFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case stdout = "STDOUT"
    case stderr = "STDERR"
    case app = "App"

    var id: String { rawValue }
}

private struct DebugConsoleView: View {
    @Environment(DebugConsoleStore.self) private var store

    @State private var filter: DebugConsoleFilter = .all
    @State private var search = ""
    @State private var autoScroll = true

    private var filteredEntries: [DebugConsoleEntry] {
        let streamFiltered: [DebugConsoleEntry] = {
            switch filter {
            case .all:
                return store.entries
            case .stdout:
                return store.entries.filter { $0.stream == .stdout }
            case .stderr:
                return store.entries.filter { $0.stream == .stderr }
            case .app:
                return store.entries.filter { $0.stream == .app }
            }
        }()

        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else { return streamFiltered }

        return streamFiltered.filter {
            $0.message.localizedCaseInsensitiveContains(trimmedSearch)
                || $0.stream.rawValue.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            controls

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredEntries) { entry in
                            DebugConsoleRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: store.entries.count) { _, _ in
                    guard autoScroll, let lastID = filteredEntries.last?.id else { return }
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .padding(10)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(DebugConsoleFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)

            Button("Copy") {
                copyLogs()
            }

            Button("Clear") {
                store.clear()
            }
        }
    }

    private func copyLogs() {
        let text = store.exportText(entries: filteredEntries)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct DebugConsoleRow: View {
    let entry: DebugConsoleEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTimestamp)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            Text(entry.stream.rawValue)
                .foregroundStyle(streamColor)
                .frame(width: 58, alignment: .leading)

            Text(entry.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
    }

    private var streamColor: Color {
        switch entry.stream {
        case .stdout:
            return .green
        case .stderr:
            return .red
        case .app:
            return .orange
        }
    }
}

private final class DebugConsoleFormatting {
    @MainActor
    static let shared = DebugConsoleFormatting()

    let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}
}
