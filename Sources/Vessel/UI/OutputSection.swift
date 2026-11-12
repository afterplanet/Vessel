import SwiftUI
import AppKit

/// Watches the running capture's folder for what it has produced so far.
@MainActor
final class LiveOutput: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let title: String
        let kind: ResultKind
        let size: Int64
        let modified: Date
        var bytesPerSecond: Double = 0
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var image: NSImage?
    @Published private(set) var imageURL: URL?
    @Published private(set) var textLines: [String] = []
    @Published private(set) var textName = ""

    private var imageStamp: Date?
    private var rawStart: (date: Date, size: Int64)?
    private var sizes: [URL: (Int64, Date)] = [:]

    func reset() {
        items = []
        image = nil
        imageURL = nil
        textLines = []
        textName = ""
        imageStamp = nil
        rawStart = nil
        sizes = [:]
    }

    /// Raw bytes per second since the file started growing, once there's enough to go on.
    func rawRate() -> Double? {
        guard let raw = items.first(where: { $0.kind == .baseband && $0.size > 0 }) else { return nil }
        guard let start = rawStart else {
            rawStart = (Date(), raw.size)
            return nil
        }
        let seconds = Date().timeIntervalSince(start.date)
        return seconds >= 8 ? Double(raw.size - start.size) / seconds : nil
    }

    func scan(_ folder: URL) async {
        let found = await Task.detached(priority: .utility) { Self.list(folder) }.value
        let now = Date()
        var out: [Item] = []
        for var item in found {
            if let (size, at) = sizes[item.url], now > at {
                item.bytesPerSecond = max(0, Double(item.size - size) / now.timeIntervalSince(at))
            }
            sizes[item.url] = (item.size, now)
            out.append(item)
        }
        if out != items { items = out }

        if let newest = found.filter({ $0.kind == .image && $0.size > 0 }).max(by: { $0.modified < $1.modified }),
           newest.url != imageURL || newest.modified != imageStamp,
           let thumb = await ResultThumbnail.thumbnail(for: newest.url) {
            image = thumb
            imageURL = newest.url
            imageStamp = newest.modified
        }
        if let newest = found.filter({ $0.kind == .readable && $0.size > 0 }).max(by: { $0.modified < $1.modified }) {
            let url = newest.url
            let lines = await Task.detached(priority: .utility) { Self.tail(url) }.value
            if lines != textLines { textLines = lines }
            textName = newest.title
        }
    }

    nonisolated private static func list(_ folder: URL) -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var out: [Item] = []
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let c = ResultClassifier.classify(name: url.lastPathComponent)
            let file = ResultFile(url: url, kind: c.kind, title: c.title, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast)
            // The app's own notes about the session aren't output.
            if ResultClassifier.isHousekeeping(file) || url.lastPathComponent == SessionInfo.fileName { continue }
            out.append(Item(url: url, title: c.title, kind: c.kind, size: file.size, modified: file.modified))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// The end of a text file. Reads only the last part, since these can grow large.
    nonisolated private static func tail(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 2000 ? size - 2000 : 0)
        guard let d = try? h.readToEnd() else { return [] }
        return Array(String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(5).map(String.init))
    }
}

/// Live results at the bottom of the sidebar: is this worth keeping, and what's coming out of it.
struct OutputSection: View {
    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var app: AppState
    @ObservedObject var health: HealthMonitor
    @ObservedObject var spectrum: SpectrumFeed
    @StateObject private var output = LiveOutput()

    private var watching: Bool { runner.isRunning || runner.isProcessing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if runner.outputDir == nil && !watching {
                Text("Start listening to see the signal's health and live output here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                healthRow
                preview
                textOutput
                fileList
            }
            Toggle("Stop if it's only noise for 2 minutes", isOn: $app.stopOnNoise)
                .controlSize(.small)
                .font(.system(size: 11))
                .help("Applies when saving the raw signal, and only while the satellite is in view or its position is unknown")
        }
        .task(id: "\(runner.outputDir?.path ?? "")|\(watching)") {
            if watching, runner.startedAt.map({ Date().timeIntervalSince($0) < 3 }) == true { output.reset() }
            guard let dir = runner.outputDir else { return }
            await output.scan(dir)
            while watching, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await output.scan(dir)
                if runner.mode == .record, let per = HealthVerdict.bytesPerSample(app.effectiveFormat), let rate = output.rawRate() {
                    let share = rate / (app.sampleRate * per)
                    health.arrival = share
                    if share < 0.7 { app.noteDelivered(bytesPerSecond: rate) }
                }
            }
        }
    }

    private var healthRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                Capsule().fill(health.verdict.level.color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(health.verdict.title).font(.system(size: 12, weight: .semibold))
                    Text(health.verdict.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !health.history.isEmpty {
                HStack(spacing: 6) {
                    HStack(spacing: 1) {
                        ForEach(Array(health.history.enumerated()), id: \.offset) { _, level in
                            Rectangle().fill(level.color).frame(maxWidth: 6, minHeight: 6, maxHeight: 6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .help("How this capture has gone: 5 seconds per block, oldest on the left")
                    Spacer(minLength: 0)
                    if let p = health.goodPercent {
                        Text("Signal \(p)% of the time").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = output.image, let url = output.imageURL {
            VStack(alignment: .leading, spacing: 3) {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Open \(url.lastPathComponent)")
                Text(url.lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } else if let picture = spectrum.waterfall, watching {
            VStack(alignment: .leading, spacing: 3) {
                Image(decorative: picture, scale: 1).resizable().interpolation(.medium)
                    .frame(maxWidth: .infinity).frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(runner.mode == .listen ? "Live signal. Pictures appear here as soon as the decoder writes them." : "Live signal. Raw recordings make pictures only once decoded.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var textOutput: some View {
        if !output.textLines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(output.textName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                ForEach(Array(output.textLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 9, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.3)))
        }
    }

    @ViewBuilder private var fileList: some View {
        if !output.items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(output.items.prefix(5)) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.kind.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 13)
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        if watching, item.bytesPerSecond >= 1 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file) + "/s")
                                .foregroundStyle(.green).monospacedDigit().lineLimit(1)
                        }
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    .font(.system(size: 10))
                }
                if output.items.count > 5 {
                    Text("and \(output.items.count - 5) more in the folder above").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
