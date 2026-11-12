import SwiftUI
import QuickLook
import QuickLookThumbnailing
import AppKit

/// Every capture, newest first. Images show as thumbnails, and anything readable opens in Quick Look.
struct ResultsView: View {
    @EnvironmentObject var results: ResultsStore
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner
    @State private var preview: URL?
    @State private var previewList: [URL] = []

    var body: some View {
        Group {
            if results.sessions.isEmpty {
                if results.isLoading {
                    ProgressView("Loading results…")
                } else {
                    ContentUnavailableView("No results yet", systemImage: "tray",
                                           description: Text("Captures appear here when you start listening."))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(results.sessions) { s in
                            SessionSection(session: s, live: runner.outputDir == s.folder && runner.isRunning) { file in open(file, in: s) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .quickLookPreview($preview, in: previewList)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { results.refresh(root: app.outputDir) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([app.outputDir]) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
        .onAppear { results.refresh(root: app.outputDir) }
        .onChange(of: runner.isRunning) { _, _ in results.refresh(root: app.outputDir) }
        // Files keep arriving during a capture.
        .task(id: runner.isRunning) {
            while runner.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                results.refresh(root: app.outputDir)
            }
        }
    }

    private func open(_ file: ResultFile, in session: ResultSession) {
        // Quick Look's arrows step through the other viewable files of this capture.
        previewList = session.files.filter { $0.kind.isViewable && !$0.isEmpty }.map(\.url)
        preview = file.url
    }
}

struct SessionSection: View {
    let session: ResultSession
    var live = false
    let onOpen: (ResultFile) -> Void

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if session.files.isEmpty {
                Text("No files yet").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(session.files) { f in ResultCard(file: f) { onOpen(f) } }
                }
            }
        }
    }

    private var timeText: String {
        let start = session.started.formatted(date: .abbreviated, time: .shortened)
        guard !live else { return "\(start), still running" }
        let seconds = Int(session.ended.timeIntervalSince(session.started))
        let end = session.ended.formatted(date: .omitted, time: .shortened)
        return seconds > 0 ? "\(start) to \(end) (\(Self.duration(seconds)))" : start
    }

    static func duration(_ s: Int) -> String { s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(session.title).font(.system(size: 14, weight: .semibold))
                if let info = session.info {
                    Text(info.decoding ? "Live decoding" : "Save to file")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.6)))
                }
                if live {
                    Label("Running", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([session.folder]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show this capture in Finder")
            }
            Text(timeText).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(session.outcome)
                if let info = session.info {
                    Text("· \(formatHz(info.frequencyHz))")
                    if let p = info.pipelineName { Text("· \(p)") }
                    if let h = info.host { Text("· \(h)") }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct ResultCard: View {
    let file: ResultFile
    let onOpen: () -> Void
    @State private var saving = false
    @State private var saveError: String?

    private var canOpen: Bool { file.kind.isViewable && !file.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onOpen) {
                ResultThumbnail(file: file)
                    .frame(height: 112)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .help(canOpen ? "Open in Quick Look" : file.isEmpty ? "This file is empty" : "This can't be previewed, but you can download it.")

            VStack(alignment: .leading, spacing: 1) {
                Text(file.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(file.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(file.modified.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(file.isEmpty ? "Empty" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 9)).foregroundStyle(file.isEmpty ? Color.orange : Color.secondary).monospacedDigit()
                Spacer()
                if canOpen {
                    Button(action: onOpen) { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("View")
                }
                Button(action: download) {
                    if saving { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.circle") }
                }
                .buttonStyle(.borderless)
                .disabled(saving || file.isEmpty)
                .help("Download a copy")
            }
            .font(.system(size: 12))
            if let saveError { Text(saveError).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2) }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.45)))
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = file.url
        saving = true
        saveError = nil
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: source, to: target)
            } catch { failure = error.localizedDescription }
            let message = failure
            await MainActor.run {
                saving = false
                saveError = message
            }
        }
    }
}

/// The picture itself for images, and the system's preview or an icon for everything else.
struct ResultThumbnail: View {
    let file: ResultFile
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: file.kind.symbol).font(.system(size: 24, weight: .light))
                    Text(file.kind.rawValue).font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
            if file.isEmpty {
                Text("No data").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .task(id: file.url) {
            guard file.kind == .image || file.kind == .readable, !file.isEmpty else { return }
            image = await Self.thumbnail(for: file.url)
        }
    }

    static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 224), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
