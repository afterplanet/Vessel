import SwiftUI

/// The SatNOGS API key. Kept in a private file on this Mac and never in the app or its source:
/// it belongs to whoever entered it.
enum SatNOGSKey {
    static var defaultFile: URL { Res.cacheDir.appendingPathComponent("satnogs_token") }

    /// Keys are 40 hex characters.
    static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil ? t : nil
    }

    static func load(from file: URL = defaultFile) -> String? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap(clean)
    }

    @discardableResult
    static func save(_ text: String, to file: URL = defaultFile) -> Bool {
        guard let key = clean(text) else { return false }
        // Only readable by this user, from the moment it exists.
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard (try? key.write(to: file, atomically: false, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }

    static func remove(from file: URL = defaultFile) { try? FileManager.default.removeItem(at: file) }
}

/// Frames that SatNOGS stations have received and decoded from a satellite. Needs a key.
@MainActor
final class SatNOGSTelemetry: ObservableObject {
    struct Frame: Decodable, Equatable, Identifiable {
        let frame: String
        let observer: String?
        let timestamp: String
        var id: String { timestamp + frame.prefix(16) }
        var date: Date? { ISO8601DateFormatter().date(from: timestamp) }
        var hex: String { Self.spaced(frame) }
        var bytes: [UInt8] {
            let digits = Array(frame.utf8)
            guard digits.count % 2 == 0 else { return [] }
            var out: [UInt8] = []
            out.reserveCapacity(digits.count / 2)
            for i in stride(from: 0, to: digits.count, by: 2) {
                guard let high = Character(UnicodeScalar(digits[i])).hexDigitValue,
                      let low = Character(UnicodeScalar(digits[i + 1])).hexDigitValue else { return [] }
                out.append(UInt8(high * 16 + low))
            }
            return out
        }

        /// "3DDB9B" reads as "3D DB 9B".
        static func spaced(_ text: String) -> String {
            var out = "", count = 0
            for c in text {
                if count > 0, count % 2 == 0 { out.append(" ") }
                out.append(c)
                count += 1
            }
            return out
        }
    }

    enum State: Equatable {
        case idle, loading, needsKey, keyRefused, failed
        case loaded([Frame])
    }

    @Published private(set) var state = State.idle

    private struct Page: Decodable { let results: [Frame] }
    private static var cache: [Int: (frames: [Frame], at: Date)] = [:]
    /// New frames arrive slowly, and this is someone's own allowance.
    private static let keep: TimeInterval = 600

    nonisolated static func parse(_ data: Data) -> [Frame]? {
        (try? JSONDecoder().decode(Page.self, from: data))?.results ?? (try? JSONDecoder().decode([Frame].self, from: data))
    }

    func load(norad: Int) async {
        guard let key = SatNOGSKey.load() else { state = .needsKey; return }
        if let hit = Self.cache[norad], Date().timeIntervalSince(hit.at) < Self.keep {
            state = .loaded(hit.frames)
            return
        }
        state = .loading
        guard let url = URL(string: "https://db.satnogs.org/api/telemetry/?satellite=\(norad)&format=json") else { return }
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(AMSATAPI.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await DataFetcher.session.data(for: request) else { state = .failed; return }
        if Task.isCancelled { return }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            let frames = Self.parse(data) ?? []
            Self.cache[norad] = (frames, Date())
            state = .loaded(frames)
        case 401, 403: state = .keyRefused
        // SatNOGS answers this way for a satellite it has no entry for, which is most of them.
        case 400, 404: state = .loaded([])
        default: state = .failed
        }
    }
}

/// Part of the Satellite panel.
struct TelemetrySection: View {
    let satellite: Satellite
    @StateObject private var telemetry = SatNOGSTelemetry()
    @State private var formats: [String] = []
    @State private var decoded: DecodedTelemetry?
    @State private var decodedDate: Date?
    @State private var valuesOpen = Snapshot.arguments.contains("--decoded-open")

    /// The newest frame this satellite's formats can read, as stations also pick up other kinds.
    private func readFrames() async {
        decoded = nil
        decodedDate = nil
        formats = await SatNOGSDecoderLibrary.shared.usableFormats(norad: satellite.satnogsNorad)
        guard case .loaded(let frames) = telemetry.state else { return }
        for f in frames.prefix(25) {
            if let got = await SatNOGSDecoderLibrary.shared.decode(f.bytes, norad: satellite.satnogsNorad) {
                decoded = got
                decodedDate = f.date
                return
            }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Telemetry").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .task(id: satellite.norad) {
            await telemetry.load(norad: satellite.satnogsNorad)
            await readFrames()
        }
    }

    @ViewBuilder private var content: some View {
        switch telemetry.state {
        case .idle, .loading: Text("Checking…").foregroundStyle(.secondary)
        case .needsKey: Text("Add a SatNOGS API key in Settings to see this").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .keyRefused: Text("SatNOGS didn't accept the API key").foregroundStyle(.orange)
        case .failed: Text("Couldn't reach SatNOGS").foregroundStyle(.secondary)
        case .loaded(let frames):
            if let latest = frames.first {
                if let decoded {
                    DisclosureGroup("\(decoded.values.count) values, as \(decoded.format)", isExpanded: $valuesOpen) {
                        VStack(alignment: .leading, spacing: 3) {
                            if let decodedDate {
                                Text(decodedDate.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            DecodedValuesList(decoded: decoded)
                        }
                        .padding(.top, 2)
                    }
                    .font(.system(size: 10))
                } else if formats.isEmpty {
                    Text("No community format to read these yet").font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let date = latest.date {
                    Text("Decoded ") + Text(date, style: .relative) + Text(" ago")
                }
                if let observer = latest.observer, !observer.isEmpty {
                    Text("by \(observer)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                DisclosureGroup("Latest \(frames.count) frames, as hex") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(frames.prefix(5)) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                if let date = f.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Text(f.hex).font(.system(size: 9, design: .monospaced)).lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        Button("Copy All as Hex") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(frames.map { "\($0.timestamp) \($0.frame)" }.joined(separator: "\n"), forType: .string)
                        }
                        .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
                .font(.system(size: 10))
            } else {
                Text("No decoded frames on SatNOGS").foregroundStyle(.secondary)
            }
        }
    }
}

/// In Settings. Never shows a saved key back.
struct SatNOGSKeySettings: View {
    @State private var entry = ""
    @State private var saved = SatNOGSKey.load() != nil
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SatNOGS API key").font(.system(size: 12, weight: .medium))
            if saved {
                HStack {
                    Label("Saved on this Mac", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    Spacer()
                    Button("Remove") {
                        SatNOGSKey.remove()
                        saved = false
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    SecureField("Paste your key", text: $entry).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button("Save") {
                        if SatNOGSKey.save(entry) {
                            entry = ""
                            problem = nil
                            saved = true
                        } else {
                            problem = "That doesn't look like a SatNOGS key: they're 40 letters and numbers."
                        }
                    }
                    .controlSize(.small).disabled(entry.isEmpty)
                }
                if let problem { Text(problem).font(.system(size: 10)).foregroundStyle(.orange) }
            }
            Text("Lets Vessel show telemetry decoded by SatNOGS stations. Get one from your account at db.satnogs.org.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
