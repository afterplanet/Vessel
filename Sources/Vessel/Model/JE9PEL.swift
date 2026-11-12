import Foundation

/// The satellite list kept by Mineo Wakita, JE9PEL. It carries satellites' own callsigns, and
/// downlinks that SatNOGS sometimes lacks. It never adds anything to transmit to.
enum JE9PEL {
    static let url = "https://www.ne.jp/asahi/hamradio/je9pel/satslist.csv"

    struct Row: Equatable {
        let name: String
        let norad: Int
        let downlinksHz: [Double]
        let mode: String
        let callsign: String
        let status: String
        var isActive: Bool { status == "active" || status == "weather sat" }
    }

    /// Frequencies in a field like "436.270/10473.350" or "435.670-435.610", in Hz.
    static func frequencies(_ field: String) -> [Double] {
        field.split(whereSeparator: { "/- ,".contains($0) }).compactMap { part in
            let digits = part.filter { $0.isNumber || $0 == "." }
            guard let mhz = Double(digits), mhz > 20, mhz < 50_000 else { return nil }
            return mhz * 1e6
        }
    }

    static func parse(_ text: String) -> [Int: [Row]] {
        var out: [Int: [Row]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 8, let norad = Int(f[1]) else { continue }
            // The downlink column, and the beacon column where that's the only one given.
            var down = frequencies(f[3])
            if down.isEmpty { down = frequencies(f[4]) }
            out[norad, default: []].append(Row(name: f[0], norad: norad, downlinksHz: down, mode: f[5], callsign: f[6], status: f[7]))
        }
        return out
    }

    /// The first callsign listed for a satellite. Some rows give several, separated by spaces.
    static func callsign(_ rows: [Row]) -> String? {
        rows.lazy.map(\.callsign).first { !$0.isEmpty }
    }

    /// Downlinks from active rows that the satellite doesn't already have, within 5 kHz.
    static func extraTransmitters(_ rows: [Row], existing: [Transmitter]) -> [Transmitter] {
        var have = existing.map(\.downlinkHz)
        var out: [Transmitter] = []
        for r in rows where r.isActive {
            for hz in r.downlinksHz where !have.contains(where: { abs($0 - hz) < 5000 }) {
                have.append(hz)
                let mode = r.mode.replacingOccurrences(of: "*", with: "")
                out.append(Transmitter(description: "From the JE9PEL list\(mode.isEmpty ? "" : ": \(mode)")", downlinkHz: hz,
                                       mode: modeWord(mode), active: true, baud: nil))
            }
        }
        return out
    }

    /// The modulation named in a mode like "9k6 GFSK CW".
    static func modeWord(_ mode: String) -> String {
        let known = ["GMSK", "GFSK", "AFSK", "BPSK", "QPSK", "FSK", "MSK", "SSTV", "APRS", "LoRa", "FM", "CW", "SSB"]
        let words = mode.uppercased().split(whereSeparator: { " /_".contains($0) }).map(String.init)
        return known.first { k in words.contains(k.uppercased()) } ?? (mode.isEmpty ? "?" : mode)
    }
}

extension SatelliteStore {
    /// Runs after the SatNOGS transmitters are in place, as it only fills gaps around them.
    func loadJE9PEL() async {
        guard let data = try? await DataFetcher.data(JE9PEL.url, cacheName: "je9pel.csv", maxAge: 7 * 86400) else { return }
        let table = await Task.detached(priority: .utility) {
            JE9PEL.parse(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        }.value
        var added = 0
        for s in satellites {
            guard let rows = table[s.norad] else { continue }
            if s.callsign == nil { s.callsign = JE9PEL.callsign(rows) }
            let extra = JE9PEL.extraTransmitters(rows, existing: s.transmitters)
            if !extra.isEmpty { s.transmitters += extra; added += extra.count }
        }
        je9pelAdded = added
        noteEnrichment()
    }
}
