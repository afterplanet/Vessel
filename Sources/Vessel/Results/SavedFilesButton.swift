import SwiftUI
import AppKit

/// The most recent saved files that mean something by themselves, newest first.
enum SavedFiles {
    struct Item: Identifiable, Equatable {
        var id: URL { file.url }
        let file: ResultFile
        let satellite: String
    }

    static func recent(_ sessions: [ResultSession], limit: Int = 40) -> [Item] {
        var items: [Item] = []
        for s in sessions {
            for f in s.files where !f.isEmpty && !ResultClassifier.isHousekeeping(f) {
                items.append(Item(file: f, satellite: s.title))
            }
        }
        return Array(items.sorted { $0.file.modified > $1.file.modified }.prefix(limit))
    }

    /// How far through the pass a capture is, when the end of the pass is known.
    static func passFraction(started: Date, pass: PassState, now: Date = Date()) -> Double? {
        guard case .pass(let p) = pass, p.los > started else { return nil }
        return min(1, max(0, now.timeIntervalSince(started) / p.los.timeIntervalSince(started)))
    }
}

/// A thin bar like the one under Safari's downloads button. With no known end, it sweeps instead.
struct SaveProgressBar: View {
    let fraction: Double?
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.35))
                if let fraction {
                    Capsule().fill(Color.accentColor).frame(width: max(height, g.size.width * fraction))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { c in
                        let t = c.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(Color.accentColor)
                            .frame(width: g.size.width * 0.4)
                            .offset(x: (g.size.width * 1.4) * t - g.size.width * 0.4)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
    }
}

/// Toolbar folder, beside the satellite search. Shows a bar while saving, and drops down the saved files.
struct SavedFilesButton: View {
    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var app: AppState
    @EnvironmentObject var results: ResultsStore
    @State private var open = false

    private var fraction: Double? {
        guard !runner.isProcessing, let started = runner.startedAt else { return nil }
        return SavedFiles.passFraction(started: started, pass: app.pass)
    }

    var body: some View {
        Button { open.toggle() } label: {
            VStack(spacing: 1) {
                Image(systemName: "folder")
                    .font(.system(size: runner.isRunning ? 13 : 15))
                if runner.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        SaveProgressBar(fraction: fraction).frame(width: 20)
                    }
                }
            }
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .help(runner.isRunning ? "Saving. Click to see saved files." : "Saved files")
        .accessibilityLabel("Saved files")
        .popover(isPresented: $open, arrowEdge: .bottom) { SavedFilesList(close: { open = false }) }
        .task(id: runner.isRunning) {
            results.refresh(root: app.outputDir)
            while runner.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                results.refresh(root: app.outputDir)
            }
        }
    }
}

struct SavedFilesList: View {
    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var app: AppState
    @EnvironmentObject var results: ResultsStore
    @Environment(\.openWindow) private var openWindow
    let close: () -> Void

    private var items: [SavedFiles.Item] { SavedFiles.recent(results.sessions) }
    private var running: ResultSession? { results.sessions.first { $0.folder == runner.outputDir && runner.isRunning } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if runner.isRunning { activeRow; Divider() }
            if items.isEmpty {
                if !runner.isRunning {
                    VStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 26, weight: .light))
                        Text("Nothing saved yet").font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { SavedFileRow(item: $0) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Button("All Results") {
                    close()
                    openWindow(id: "results")
                }
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: app.outputDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([app.outputDir])
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 350)
        .task { results.refresh(root: app.outputDir) }
    }

    private var activeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: runner.mode == .record ? "square.and.arrow.down" : "headphones")
                .font(.system(size: 18)).frame(width: 30).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(running?.title ?? app.locked?.name ?? "Capture").font(.system(size: 12, weight: .medium)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 3) {
                        SaveProgressBar(fraction: runner.isProcessing ? nil : runner.startedAt.flatMap { SavedFiles.passFraction(started: $0, pass: app.pass) })
                        Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
            }
            if !runner.isProcessing {
                Button { app.stopCapture() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.borderless)
                    .help("Stop")
            }
            if let dir = runner.outputDir {
                Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: { Image(systemName: "magnifyingglass.circle") .font(.system(size: 16))}
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var statusText: String {
        if runner.isProcessing { return "Making images and products…" }
        let total = (running?.files ?? []).reduce(Int64(0)) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        if runner.mode == .record { return "Saving, \(size), about \(app.fileRateText)" }
        return total > 0 ? "Decoding, \(size) so far" : "Decoding…"
    }
}

struct SavedFileRow: View {
    let item: SavedFiles.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button { NSWorkspace.shared.open(item.file.url) } label: {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.url.path))
                        .resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.file.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Text("\(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)), \(item.satellite)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.file.modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(item.file.name)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.file.url]) } label: {
                Image(systemName: "magnifyingglass.circle").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.07) : .clear)
        .onHover { hovering = $0 }
    }
}
