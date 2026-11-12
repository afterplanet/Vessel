import Foundation
import CryptoKit

/// The saved logic for choosing a decoder, and every choice it has made.
enum PipelineRules {
    struct Rule: Codable {
        let match: String
        let pipelines: [String]
        var frequencyMHz: Double?
    }
    struct File: Codable {
        let version: Int
        var about: String?
        let rules: [Rule]
    }

    /// A copy lives in Application Support so it can be read and edited. The bundled one replaces
    /// it only when it's a newer version.
    static var savedURL: URL { Res.cacheDir.appendingPathComponent("pipeline_rules.json") }

    static func load() -> [Rule] {
        func read(_ u: URL?) -> File? {
            u.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        }
        let bundled = read(Res.url("pipeline_rules.json"))
        let saved = read(savedURL)
        if let bundled, (saved?.version ?? -1) < bundled.version, let u = Res.url("pipeline_rules.json") {
            try? FileManager.default.removeItem(at: savedURL)
            try? FileManager.default.copyItem(at: u, to: savedURL)
            return bundled.rules
        }
        return saved?.rules ?? bundled?.rules ?? []
    }

    static func rule(for name: String, in rules: [Rule]) -> Rule? {
        rules.first { name.range(of: $0.match, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

/// A decoder picked by hand for a satellite wins over the rules, and survives restarts.
@MainActor
final class PipelineChoices {
    struct Entry: Codable, Equatable {
        var satellite: String
        var pipeline: String?
        var manual: Bool
        var reason: String
        var updated: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private let url: URL

    init(url: URL = Res.cacheDir.appendingPathComponent("pipeline_choices.json")) {
        self.url = url
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let e = try? d.decode([String: Entry].self, from: data) { entries = e }
    }

    func manual(norad: Int) -> String? {
        let e = entries[String(norad)]
        return e?.manual == true ? e?.pipeline : nil
    }

    func recordAuto(norad: Int, satellite: String, pipeline: String?, reason: String) {
        guard entries[String(norad)]?.manual != true else { return }
        let old = entries[String(norad)]
        guard old?.pipeline != pipeline || old?.reason != reason else { return }
        entries[String(norad)] = Entry(satellite: satellite, pipeline: pipeline, manual: false, reason: reason, updated: Date())
        save()
    }

    func setManual(norad: Int, satellite: String, pipeline: String?) {
        if let pipeline {
            entries[String(norad)] = Entry(satellite: satellite, pipeline: pipeline, manual: true, reason: "Chosen by hand", updated: Date())
        } else {
            entries[String(norad)] = nil
        }
        save()
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(entries) { try? d.write(to: url, options: .atomic) }
    }
}

/// Looks for newer decoder definitions when the app starts. Changed files are downloaded and merged
/// into the engine's own override file, so the engine itself is never modified. Anything the engine
/// won't load is dropped again, so an update can't take away a decoder that works today.
enum PipelineUpdater {
    static let listURL = URL(string: "https://api.github.com/repos/SatDump/SatDump/contents/resources/pipelines?ref=master")!

    /// Where the engine runs from, and so where it finds `pipelines.json`.
    static var runDir: URL {
        let d = Res.cacheDir.appendingPathComponent("engine-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var overrideFile: URL { runDir.appendingPathComponent("pipelines.json") }
    static var downloadDir: URL {
        let d = Res.cacheDir.appendingPathComponent("pipeline-updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private struct Listing: Decodable {
        let name: String
        let sha: String
        let download_url: String?
    }

    struct Outcome: Equatable {
        var checked: Bool
        var updatedFiles: [String]
        var rejectedFiles: [String]
        var message: String
    }

    /// Git's own checksum for a file, which is what the listing reports.
    static func blobSHA(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The text between a JSON object's outer braces, keeping its order: decoder steps run in file order.
    static func objectBody(_ text: String) -> String? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return String(text[text.index(after: a)..<b]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func merge(_ files: [String]) -> String {
        "{\n" + files.compactMap(objectBody).filter { !$0.isEmpty }.joined(separator: ",\n") + "\n}\n"
    }

    /// Top-level decoder IDs in one definition file.
    static func decoderIDs(_ data: Data) -> [String] {
        ((try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]).map { Array($0.keys) } ?? []
    }

    static func checkForUpdates(engine: URL, installed: URL?) async -> Outcome {
        var request = URLRequest(url: listURL)
        request.timeoutInterval = 15
        request.setValue("Vessel/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let listing = try? JSONDecoder().decode([Listing].self, from: data) else {
            return Outcome(checked: false, updatedFiles: [], rejectedFiles: [], message: "Couldn't check for decoder updates")
        }

        let fm = FileManager.default
        var kept: [String] = [] // files that differ from what the engine ships with
        var fetched: [String] = []
        for item in listing where item.name.hasSuffix(".json") {
            let shipped = installed.flatMap { try? Data(contentsOf: $0.appendingPathComponent(item.name)) }
            if let shipped, blobSHA(shipped) == item.sha {
                try? fm.removeItem(at: downloadDir.appendingPathComponent(item.name))
                continue
            }
            let local = downloadDir.appendingPathComponent(item.name)
            if let have = try? Data(contentsOf: local), blobSHA(have) == item.sha {
                kept.append(item.name)
                continue
            }
            guard let link = item.download_url.flatMap(URL.init(string:)),
                  let (body, r) = try? await URLSession.shared.data(from: link), (r as? HTTPURLResponse)?.statusCode == 200,
                  !decoderIDs(body).isEmpty else { continue }
            try? body.write(to: local, options: .atomic)
            kept.append(item.name)
            fetched.append(item.name)
        }

        // Nothing changed since the last launch, and the override is already in place.
        if fetched.isEmpty, fm.fileExists(atPath: overrideFile.path) || kept.isEmpty {
            if kept.isEmpty { try? fm.removeItem(at: overrideFile) }
            return Outcome(checked: true, updatedFiles: [], rejectedFiles: [],
                           message: kept.isEmpty ? "Decoders are up to date" : "Decoders are up to date, \(kept.count) file\(kept.count == 1 ? "" : "s") newer than the engine's")
        }

        // Add one file at a time against the engine, keeping only what it loads and what doesn't
        // cost a decoder it already had.
        let baseline = await loadedDecoders(engine: engine, override: nil)
        var accepted: [String] = []
        var rejected: [String] = []
        for name in kept.sorted() {
            guard let text = try? String(contentsOf: downloadDir.appendingPathComponent(name), encoding: .utf8),
                  let raw = text.data(using: .utf8) else { continue }
            let candidate = merge((accepted + [name]).compactMap { try? String(contentsOf: downloadDir.appendingPathComponent($0), encoding: .utf8) })
            let loaded = await loadedDecoders(engine: engine, override: candidate)
            let ids = Set(decoderIDs(raw))
            // Everything it had before must survive, and so must this file's own decoders.
            if !baseline.isEmpty, baseline.isSubset(of: loaded), ids.isSubset(of: loaded) {
                accepted.append(name)
            } else {
                rejected.append(name)
            }
        }
        if accepted.isEmpty {
            try? fm.removeItem(at: overrideFile)
        } else {
            let final = merge(accepted.compactMap { try? String(contentsOf: downloadDir.appendingPathComponent($0), encoding: .utf8) })
            try? final.write(to: overrideFile, atomically: true, encoding: .utf8)
        }
        let n = accepted.count
        return Outcome(checked: true, updatedFiles: accepted, rejectedFiles: rejected,
                       message: n == 0 ? "Decoders are up to date" : "\(n) decoder file\(n == 1 ? "" : "s") updated")
    }

    /// What the engine actually loads with a given override, from its own list of decoders.
    static func loadedDecoders(engine: URL, override: String?) async -> Set<String> {
        await Task.detached(priority: .utility) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vessel-probe-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            if let override { try? override.write(to: dir.appendingPathComponent("pipelines.json"), atomically: true, encoding: .utf8) }
            let p = Process()
            p.executableURL = engine
            p.arguments = ["pipeline", "--help"]
            p.currentDirectoryURL = dir
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard let r = text.range(of: "SUBCOMMANDS:") else { return [] }
            var ids = Set<String>()
            for line in text[r.upperBound...].split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let first = t.split(separator: " ").first { ids.insert(String(first)) }
            }
            return ids
        }.value
    }
}
