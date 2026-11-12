import SwiftUI

/// The community's telemetry definitions (libre.space's satnogs-decoders), which turn the bytes of a
/// received frame into named values. They are downloaded rather than included, are read only as data,
/// and are kept up to date from their repository.
enum SatNOGSDecoderFiles {
    static let commitsURL = "https://gitlab.com/api/v4/projects/librespacefoundation%2Fsatnogs%2Fsatnogs-decoders/repository/commits?per_page=1"
    static let commitCache = "satnogs_decoders_commit.json"
    static let maxArchive = 30_000_000
    static let maxDefinition = 8_000_000
    /// A far smaller download than this is a broken one, so it doesn't replace what's already here.
    static let fewestDefinitions = 50

    static var folder: URL { Res.cacheDir.appendingPathComponent("satnogs_decoders") }
    static var versionFile: URL { folder.appendingPathComponent("VERSION") }

    static func archiveURL(commit: String) -> String {
        "https://gitlab.com/librespacefoundation/satnogs/satnogs-decoders/-/archive/\(commit)/satnogs-decoders-\(commit).tar.gz"
    }

    static func isCommit(_ text: String) -> Bool {
        text.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    static func latestCommit(in data: Data) -> String? {
        struct Row: Decodable { let id: String }
        guard let id = (try? JSONDecoder().decode([Row].self, from: data))?.first?.id, isCommit(id) else { return nil }
        return id
    }

    static func isDefinitionName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]+\\.ksy$", options: .regularExpression) != nil
    }

    static var installedCommit: String? {
        (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var installedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".ksy") }.count
    }

    /// Takes only plain .ksy files out of an unpacked archive: nothing else in it is used, or ever run.
    static func collect(from unpacked: URL, into staging: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let walker = fm.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return 0 }
        var count = 0
        for case let file as URL in walker {
            guard file.deletingLastPathComponent().lastPathComponent == "ksy", isDefinitionName(file.lastPathComponent) else { continue }
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? .max) <= maxDefinition else { continue }
            try fm.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            count += 1
        }
        return count
    }

    /// Unpacks an archive and replaces the installed definitions, or leaves them alone if anything's wrong.
    static func install(archive: Data, commit: String) throws -> Int {
        guard archive.count <= maxArchive, isCommit(commit) else { throw URLError(.dataLengthExceedsMaximum) }
        let fm = FileManager.default
        let work = Res.cacheDir.appendingPathComponent("satnogs_decoders_update_\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let tarball = work.appendingPathComponent("archive.tar.gz")
        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try archive.write(to: tarball)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // tar keeps everything inside the folder it's given, as it refuses absolute paths and "..".
        tar.arguments = ["-xzf", tarball.path, "-C", unpacked.path, "--include", "*/ksy/*.ksy"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw URLError(.cannotDecodeContentData) }

        let staging = work.appendingPathComponent("staging")
        let count = try collect(from: unpacked, into: staging)
        guard count >= fewestDefinitions else { throw URLError(.cannotDecodeContentData) }
        try commit.write(to: staging.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
        return count
    }

    enum Outcome: Equatable {
        case current(Int), updated(Int), unavailable

        var words: String {
            switch self {
            case .current(let n): "\(n) telemetry formats are current"
            case .updated(let n): "Telemetry formats updated: \(n) available"
            case .unavailable: "Couldn't reach the telemetry format repository"
            }
        }
    }

    @MainActor private static var running: Task<Outcome, Never>?

    /// Asks at most once a day, and downloads only when the repository has changed. Launching and
    /// checking by hand can overlap, and two of these replacing the same folder would lose it.
    @MainActor static func update() async -> Outcome {
        if let running { return await running.value }
        let task = Task { await fetchAndInstall() }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    private static func fetchAndInstall() async -> Outcome {
        let have = installedCount
        guard let data = try? await DataFetcher.data(commitsURL, cacheName: commitCache, maxAge: 86400, userAgent: AMSATAPI.userAgent),
              let latest = latestCommit(in: data) else {
            return have > 0 ? .current(have) : .unavailable
        }
        if latest == installedCommit, have > 0 { return .current(have) }
        guard let url = URL(string: archiveURL(commit: latest)) else { return .unavailable }
        var request = URLRequest(url: url)
        request.setValue(AMSATAPI.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (archive, response) = try? await DataFetcher.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return have > 0 ? .current(have) : .unavailable
        }
        let installed = await Task.detached(priority: .utility) { try? install(archive: archive, commit: latest) }.value
        guard let installed else { return have > 0 ? .current(have) : .unavailable }
        await SatNOGSDecoderLibrary.shared.reload()
        return .updated(installed)
    }

    /// Which definitions SatNOGS lists for each satellite, from its satellite list.
    static func assignments(in data: Data) -> [Int: [String]] {
        struct Row: Decodable {
            struct Telemetry: Decodable { let decoder: String? }
            let norad_cat_id: Int?
            let telemetries: [Telemetry]?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [:] }
        var out: [Int: [String]] = [:]
        for row in rows {
            guard let n = row.norad_cat_id else { continue }
            for name in (row.telemetries ?? []).compactMap(\.decoder) where !name.isEmpty && !(out[n] ?? []).contains(name) {
                out[n, default: []].append(name)
            }
        }
        return out
    }
}

struct DecodedTelemetry: Equatable, Sendable {
    struct Value: Equatable, Identifiable, Sendable {
        let name: String
        let value: String
        var id: String { name }

        /// "battery_1_voltage" reads as "Battery 1 voltage".
        var title: String {
            let words = name.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    let format: String
    let values: [Value]

    /// The AX.25 address fields say nothing about the satellite, and the packet list shows the callsigns anyway.
    static func isAddressField(_ name: String) -> Bool {
        let n = name.lowercased()
        if ["ctl", "pid", "control", "mtype"].contains(n) { return true }
        return n.hasPrefix("rpt_") || n.hasPrefix("rpt") && n.contains("instance")
            || ["dest_callsign", "src_callsign", "dest_ssid", "src_ssid"].contains(n)
    }
}

/// Reads frames with the installed definitions. One at a time, since a definition keeps state while reading.
actor SatNOGSDecoderLibrary {
    static let shared = SatNOGSDecoderLibrary()

    private var assigned: [Int: [String]]?
    private var loaded: [String: KaitaiDecoder] = [:]
    private var unusable = Set<String>()

    func reload() {
        assigned = nil
        loaded = [:]
        unusable = []
    }

    func formats(norad: Int) -> [String] {
        if assigned == nil {
            let file = Res.cacheDir.appendingPathComponent("satnogs_satellites.json")
            // Not cached while the list is still on its way, so it's picked up once it arrives.
            guard let data = try? Data(contentsOf: file) else { return [] }
            assigned = SatNOGSDecoderFiles.assignments(in: data)
        }
        return assigned?[norad] ?? []
    }

    /// Definitions that are listed for this satellite and actually installed.
    func usableFormats(norad: Int) -> [String] {
        formats(norad: norad).filter { decoder(named: $0) != nil }
    }

    private func decoder(named name: String) -> KaitaiDecoder? {
        if let d = loaded[name] { return d }
        guard !unusable.contains(name), SatNOGSDecoderFiles.isDefinitionName(name + ".ksy") else { return nil }
        let file = SatNOGSDecoderFiles.folder.appendingPathComponent(name + ".ksy")
        guard let text = try? String(contentsOf: file, encoding: .utf8), let d = try? KaitaiDecoder(yaml: text) else {
            unusable.insert(name)
            return nil
        }
        loaded[name] = d
        return d
    }

    /// The listed format that makes the most of this frame, if any make anything of it.
    func decode(_ frame: [UInt8], norad: Int) -> DecodedTelemetry? {
        var best: DecodedTelemetry?
        for name in formats(norad: norad) {
            guard let values = decoder(named: name)?.decode(frame) else { continue }
            let useful = values.filter { !DecodedTelemetry.isAddressField($0.name) }.map { DecodedTelemetry.Value(name: $0.name, value: $0.value) }
            if !useful.isEmpty, useful.count > (best?.values.count ?? 0) { best = DecodedTelemetry(format: name, values: useful) }
        }
        return best
    }
}

/// A frame's values, in a list of two columns.
struct DecodedValuesList: View {
    let decoded: DecodedTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(decoded.values.prefix(200)) { v in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(v.title).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(v.value).monospacedDigit().lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                .font(.system(size: 10))
            }
        }
    }
}

/// Under a packet in the capture list, once it's been read with the satellite's format.
struct PacketValues: View {
    let frame: [UInt8]
    let norad: Int?
    @State private var decoded: DecodedTelemetry?

    var body: some View {
        Group {
            if let decoded {
                DisclosureGroup("\(decoded.values.count) values") {
                    DecodedValuesList(decoded: decoded).padding(.top, 2)
                }
                .font(.system(size: 10))
            }
        }
        .task(id: frame) {
            guard let norad else { return }
            decoded = await SatNOGSDecoderLibrary.shared.decode(frame, norad: norad)
        }
    }
}
