import Foundation
import SwiftUI

/// Written beside a capture's files, so its results can always be explained later.
struct SessionInfo: Codable, Equatable {
    var satellite: String
    var norad: Int
    var frequencyHz: Double
    var sampleRate: Double
    var pipelineName: String?
    var decoding: Bool
    var source: String
    var host: String?
    var started: Date
    var ended: Date?
    /// As listed when the capture started.
    var format: String? = nil

    static let fileName = "session.json"

    func write(to dir: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) { try? d.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic) }
    }

    static func read(from dir: URL) -> SessionInfo? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: dir.appendingPathComponent(fileName))).flatMap { try? d.decode(SessionInfo.self, from: $0) }
    }
}

enum ResultKind: String, CaseIterable {
    case image = "Image"
    case readable = "Readable"
    case audio = "Audio"
    case baseband = "Raw signal"
    case decodedData = "Decoded data"
    case product = "Data product"
    case other = "File"

    var symbol: String {
        switch self {
        case .image: "photo"
        case .readable: "doc.text"
        case .audio: "waveform"
        case .baseband: "waveform.path"
        case .decodedData: "square.stack.3d.up"
        case .product: "shippingbox"
        case .other: "doc"
        }
    }

    /// Whether Quick Look can show the contents.
    var isViewable: Bool { self == .image || self == .readable || self == .audio }
}

struct ResultFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let kind: ResultKind
    let title: String
    let size: Int64
    let modified: Date

    var name: String { url.lastPathComponent }
    var isEmpty: Bool { size == 0 }
}

struct ResultSession: Identifiable, Equatable {
    var id: URL { folder }
    let folder: URL
    let info: SessionInfo?
    let title: String
    let started: Date
    let ended: Date
    let files: [ResultFile]

    var images: Int { files.filter { $0.kind == .image }.count }

    /// Says plainly when a capture ran but nothing came out of it.
    var outcome: String {
        let usable = files.filter { !$0.isEmpty && !ResultClassifier.isHousekeeping($0) }
        // The most useful thing a capture produced is what it's described by.
        if images > 0 { return "\(images) image\(images == 1 ? "" : "s") decoded" }
        if files.contains(where: { $0.kind == .audio && !$0.isEmpty }) { return "Audio saved" }
        if files.contains(where: { $0.kind == .decodedData && !$0.isEmpty }) { return "Frames decoded, with no images" }
        if files.contains(where: { $0.kind == .baseband && !$0.isEmpty }) { return "Saved the raw signal, ready for decoding later" }
        if usable.isEmpty { return "Nothing decoded. The signal may have been too weak." }
        return "Files saved"
    }
}

enum ResultClassifier {
    private static let images: Set<String> = ["png", "jpg", "jpeg", "jp2", "tif", "tiff", "gif", "bmp", "webp", "heic"]
    private static let text: Set<String> = ["txt", "json", "csv", "log", "xml", "html", "htm", "md", "yaml", "yml", "tle"]
    private static let audio: Set<String> = ["mp3", "m4a", "aac", "flac", "ogg"]
    private static let baseband: Set<String> = ["cf32", "cs32", "cs16", "cs8", "cu8", "wav16", "ziq", "ziq2", "iq", "raw"]
    private static let decoded: [String: String] = [
        "cadu": "Decoded frames (CADU)", "vcdu": "Decoded frames (VCDU)", "frm": "Decoded frames", "frames": "Decoded frames",
        "soft": "Soft symbols", "ccsds": "CCSDS packets", "lrit": "LRIT file", "hrit": "HRIT file", "bin": "Binary data",
        "raw16": "Raw 16-bit data", "tip": "Instrument data", "hrpt": "HRPT frames", "gac": "GAC frames", "dsb": "DSB frames",
    ]

    static func classify(name: String) -> (kind: ResultKind, title: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension.lowercased()
        if images.contains(ext) { return (.image, prettyImageName(stem)) }
        if name == "dataset.json" { return (.readable, "Processing summary") }
        if name == "telemetry.json" { return (.readable, "Telemetry") }
        if text.contains(ext) { return (.readable, ext == "json" ? "JSON data" : ext == "csv" ? "Table (CSV)" : ext == "log" ? "Log" : "Text") }
        if ext == "wav", stem.hasPrefix("baseband") { return (.baseband, "Raw signal (WAV)") }
        if ext == "wav" { return (.audio, "Demodulated audio") }
        if audio.contains(ext) { return (.audio, "Audio") }
        if baseband.contains(ext) { return (.baseband, "Raw signal (\(ext))") }
        if ext == "cbor" { return (.product, "Data product") }
        if let title = decoded[ext] { return (.decodedData, title) }
        return (.other, ext.isEmpty ? "File" : "\(ext.uppercased()) file")
    }

    private static func prettyImageName(_ stem: String) -> String {
        let t = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return t.isEmpty ? "Image" : t.prefix(1).uppercased() + t.dropFirst()
    }

    /// Bookkeeping SatDump always writes, which doesn't count as a result by itself.
    static func isHousekeeping(_ f: ResultFile) -> Bool {
        f.name == "dataset.json" || f.name == "telemetry.json" || f.kind == .product || f.size < 8
    }

    /// Reads one capture's folder. Images come first, then whatever else is worth opening.
    static func session(at folder: URL) -> ResultSession? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var files: [ResultFile] = []
        for case let url as URL in walker {
            guard url.lastPathComponent != SessionInfo.fileName, let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let c = classify(name: url.lastPathComponent)
            files.append(ResultFile(url: url, kind: c.kind, title: c.title, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        let info = SessionInfo.read(from: folder)
        guard !files.isEmpty || info != nil else { return nil }
        let order = Dictionary(uniqueKeysWithValues: ResultKind.allCases.enumerated().map { ($1, $0) })
        files.sort { (order[$0.kind]!, $0.name) < (order[$1.kind]!, $1.name) }
        let folderDate = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let last = files.map(\.modified).max()
        return ResultSession(folder: folder, info: info, title: info?.satellite ?? legacyTitle(folder.lastPathComponent),
                             started: info?.started ?? folderDate, ended: info?.ended ?? last ?? folderDate, files: files)
    }

    /// Folders from before `session.json` were named SATELLITE_2026-11-04T05-08-07Z.
    private static func legacyTitle(_ folder: String) -> String {
        guard let r = folder.range(of: #"_\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) else { return folder }
        return folder[..<r.lowerBound].replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class ResultsStore: ObservableObject {
    @Published private(set) var sessions: [ResultSession] = []
    @Published private(set) var isLoading = false
    private var generation = 0

    func refresh(root: URL) {
        generation += 1
        let gen = generation
        isLoading = sessions.isEmpty
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let found = folders
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .compactMap(ResultClassifier.session(at:))
                .sorted { $0.started > $1.started }
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                if found != self.sessions { self.sessions = found }
                self.isLoading = false
            }
        }
    }
}
