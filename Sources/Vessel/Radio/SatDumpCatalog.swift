import Foundation

/// One SatDump source as it appears on the CLI (`--source <id>`).
struct SDRSource: Identifiable, Hashable {
    enum Kind: String { case spy = "Public network", network = "Network", usb = "Hardware" }
    let id: String
    let name: String
    let kind: Kind
    /// The gain flag this source reads, if it has a single one.
    var gainFlag: String? = nil
    var gainRange: ClosedRange<Double> = 0...49
    var hasBias: Bool = false
    var addressFlag: String? = nil
    var defaultPort: Int? = nil
    var bitDepths: [Int] = []
    var maxSampleRate: Double = 10e6
    var extraFlags: [String] = []
    /// Listened to in a browser. SatDump has no source for these.
    var browserOnly: Bool = false

    /// Sample rates to try when scanning, narrowest useful first. Some radios accept only a few.
    var scanRates: [Double] {
        switch id {
        case "airspy", "hydrasdr": return [3_000_000, 2_500_000, 6_000_000, 10_000_000]
        case "airspyhf": return [768_000, 912_000, 456_000]
        case "rtlsdr", "rtltcp": return [2_048_000, 2_400_000, 1_024_000]
        default: return [2_000_000, 2_048_000, 2_500_000, 1_000_000]
        }
    }
}

/// How to switch on automatic gain for a source, checked against SatDump's own source code.
struct AGCSpec {
    /// The plugin file, and a setting name it must contain, to confirm the installed SatDump has this.
    let plugin: String
    let marker: String
    let args: [String]
    /// False where the manual gain slider still applies alongside AGC.
    let replacesGain: Bool
    let summary: String
}

enum SDRCatalog {
    static let agc: [String: AGCSpec] = [
        "rtlsdr": AGCSpec(plugin: "librtlsdr_sdr_support", marker: "tuner_agc", args: ["--lna_agc", "--tuner_agc"], replacesGain: true, summary: "RTL and tuner AGC"),
        "rtltcp": AGCSpec(plugin: "librtltcp_support", marker: "tuner_agc", args: ["--lna_agc", "--tuner_agc"], replacesGain: true, summary: "Asks the server for RTL and tuner AGC"),
        "airspy": AGCSpec(plugin: "libairspy_sdr_support", marker: "mixer_agc", args: ["--gain_type", "2", "--lna_agc", "--mixer_agc"], replacesGain: true, summary: "LNA and mixer AGC"),
        "hydrasdr": AGCSpec(plugin: "libhydrasdr_sdr_support", marker: "mixer_agc", args: ["--gain_type", "2", "--lna_agc", "--mixer_agc"], replacesGain: true, summary: "LNA and mixer AGC"),
        "airspyhf": AGCSpec(plugin: "libairspyhf_sdr_support", marker: "agc_mode", args: ["--agc_mode", "1"], replacesGain: false, summary: "HF AGC, low threshold"),
        "sdrplay": AGCSpec(plugin: "libsdrplay_sdr_support", marker: "agc_mode", args: ["--agc_mode", "2"], replacesGain: true, summary: "IF AGC at 50 Hz"),
        "plutosdr": AGCSpec(plugin: "libplutosdr_sdr_support", marker: "gain_mode", args: ["--gain_mode", "2"], replacesGain: true, summary: "Slow-attack AGC"),
        "bladerf": AGCSpec(plugin: "libbladerf_sdr_support", marker: "gain_mode", args: ["--gain_mode", "0"], replacesGain: true, summary: "The radio's default AGC"),
        "aaronia": AGCSpec(plugin: "libaaronia_sdr_support", marker: "agc_mode", args: ["--agc_mode", "2"], replacesGain: false, summary: "Power AGC"),
    ]

    /// Why a source has no AGC, in terms of who does control its gain.
    static func noAGCReason(_ s: SDRSource) -> String {
        switch s.id {
        case "spyserver": "SpyServer has no AGC control. The server's owner sets the receiver's gain."
        case "websdr": "Web SDRs run in the browser, so this app doesn't control them."
        case "sdrpp_server": "AGC on an SDR++ Server is set on the server itself."
        case "net_source": "This is a plain sample stream, with no receiver to control."
        default: "\(s.name) has no AGC here. Use the gain setting."
        }
    }

    static let sources: [SDRSource] = [
        SDRSource(id: "spyserver", name: "SpyServer", kind: .spy,
                  gainFlag: "digital_gain", gainRange: 0...16, addressFlag: "ip_address", defaultPort: 5555, bitDepths: [8, 16, 32]),
        SDRSource(id: "websdr", name: "Web SDR (browser only)", kind: .spy, browserOnly: true),
        SDRSource(id: "sdrpp_server", name: "SDR++ Server", kind: .network,
                  addressFlag: "ip_address", defaultPort: 5259, bitDepths: [8, 16, 32]),
        SDRSource(id: "rtltcp", name: "RTL-TCP", kind: .network,
                  gainFlag: "gain", gainRange: 0...49, hasBias: true, addressFlag: "ip_address", defaultPort: 1234, maxSampleRate: 3.2e6),
        SDRSource(id: "plutosdr", name: "PlutoSDR", kind: .network,
                  gainFlag: "gain", gainRange: 0...73, addressFlag: "ip_address", maxSampleRate: 20e6),
        SDRSource(id: "net_source", name: "Network Source", kind: .network,
                  addressFlag: "address", defaultPort: 8888),
        SDRSource(id: "rtlsdr", name: "RTL-SDR", kind: .usb,
                  gainFlag: "gain", gainRange: 0...49, hasBias: true, maxSampleRate: 3.2e6),
        SDRSource(id: "airspy", name: "Airspy Mini / R2", kind: .usb,
                  gainFlag: "general_gain", gainRange: 0...21, hasBias: true, maxSampleRate: 10e6),
        SDRSource(id: "airspyhf", name: "Airspy HF+", kind: .usb,
                  gainFlag: "attenuation", gainRange: 0...48, maxSampleRate: 768e3),
        SDRSource(id: "hydrasdr", name: "HydraSDR", kind: .usb,
                  gainFlag: "general_gain", gainRange: 0...21, hasBias: true, maxSampleRate: 10e6),
        SDRSource(id: "hackrf", name: "HackRF", kind: .usb,
                  gainFlag: "lna_gain", gainRange: 0...40, hasBias: true, maxSampleRate: 20e6),
        SDRSource(id: "sdrplay", name: "SDRplay", kind: .usb,
                  gainFlag: "if_gain", gainRange: 20...59, hasBias: true, maxSampleRate: 10e6),
        SDRSource(id: "limesdr", name: "LimeSDR", kind: .usb,
                  gainFlag: "gain", gainRange: 0...73, maxSampleRate: 61.44e6),
        SDRSource(id: "bladerf", name: "bladeRF", kind: .usb,
                  gainFlag: "general_gain", gainRange: 0...60, hasBias: true, maxSampleRate: 61.44e6),
        SDRSource(id: "usrp", name: "USRP", kind: .usb,
                  gainFlag: "gain", gainRange: 0...76, bitDepths: [8, 16], maxSampleRate: 61.44e6),
        SDRSource(id: "mirisdr", name: "Mirics / MSi", kind: .usb,
                  gainFlag: "gain", gainRange: 0...49, hasBias: true, maxSampleRate: 10e6),
        SDRSource(id: "fobos", name: "Fobos SDR", kind: .usb, maxSampleRate: 50e6),
        SDRSource(id: "aaronia", name: "Aaronia RTSA", kind: .usb, maxSampleRate: 92e6),
        SDRSource(id: "rfnm", name: "RFNM", kind: .usb, maxSampleRate: 153e6),
    ]
    static func source(_ id: String) -> SDRSource? { sources.first { $0.id == id } }

    /// What each radio can tune, in Hz, from its published specifications. Nil where it depends on what's
    /// at the other end: a network stream could be anything.
    static func tunableRanges(_ id: String) -> [ClosedRange<Double>]? {
        func mhz(_ low: Double, _ high: Double) -> ClosedRange<Double> { (low * 1e6)...(high * 1e6) }
        switch id {
        case "rtlsdr", "rtltcp": return [mhz(24, 1766)]
        case "airspy", "hydrasdr": return [mhz(24, 1800)]
        case "airspyhf": return [mhz(0.0005, 31), mhz(60, 260)]
        case "hackrf": return [mhz(1, 6000)]
        case "sdrplay": return [mhz(0.001, 2000)]
        case "limesdr": return [mhz(0.1, 3800)]
        case "bladerf": return [mhz(47, 6000)]
        case "usrp": return [mhz(70, 6000)]
        case "mirisdr": return [mhz(0.15, 1900)]
        case "fobos": return [mhz(50, 6000)]
        case "plutosdr": return [mhz(325, 3800)]
        default: return nil
        }
    }

    /// "24 to 1,766 MHz", or several joined.
    static func describe(_ ranges: [ClosedRange<Double>]) -> String {
        func number(_ hz: Double) -> String {
            if hz >= 1e9 { return String(format: "%g GHz", hz / 1e9) }
            if hz >= 1e6 { return "\(Int((hz / 1e6).rounded()).formatted()) MHz" }
            return String(format: "%g kHz", hz / 1e3)
        }
        return ranges.map { "\(number($0.lowerBound)) to \(number($0.upperBound))" }.joined(separator: ", ")
    }

    /// Joins ranges that touch or overlap, so several hosts read as one span.
    /// The first active downlink a receiver can reach, for when the usual one is out of its range.
    static func reachableDownlink(of transmitters: [Transmitter], in ranges: [ClosedRange<Double>]) -> Double? {
        transmitters.first { t in t.active && t.downlinkHz > 0 && ranges.contains { $0.contains(t.downlinkHz) } }?.downlinkHz
    }

    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// Why the start button can't be pressed.
struct StartProblem: Equatable {
    let message: String
    /// The raw signal can still be saved, even with nothing to decode it.
    var canSaveInstead = false

    static func noDecoder(satellite: String, encryption: EncryptionInfo.State?) -> String {
        switch encryption {
        case .yes: "\(satellite) is encrypted, so there's no public decoder."
        case .partly: "\(satellite) is partly encrypted, and there's no public decoder for its open links."
        default: "There's no decoder for \(satellite)'s signal."
        }
    }

    static func check(satellite: String?, encryption: EncryptionInfo.State?, engineMissing: Bool, browserOnly: Bool, hasFrequency: Bool,
                      decoding: Bool, hasDecoder: Bool, needsAddress: Bool, isSpy: Bool) -> StartProblem? {
        guard let satellite else { return StartProblem(message: "Lock a satellite first.") }
        if engineMissing { return StartProblem(message: "The receiving engine is missing from this copy of Vessel.") }
        if browserOnly { return StartProblem(message: "Web SDRs only open in a browser, so they can't be captured.") }
        if !hasFrequency {
            return StartProblem(message: encryption == .yes
                ? "\(satellite)'s downlink is encrypted, and its frequency isn't public."
                : "No public frequency is listed for \(satellite). Try Scan in the Satellite panel.")
        }
        if decoding, !hasDecoder {
            return StartProblem(message: noDecoder(satellite: satellite, encryption: encryption), canSaveInstead: !needsAddress)
        }
        if needsAddress { return StartProblem(message: isSpy ? "Pick a spy host to listen through." : "Enter the source address.") }
        return nil
    }
}

/// The least sample rate that holds a signal. Rate beyond this adds nothing for decoding, but
/// public hosts have hard limits on what they can send, so asking for more just loses samples.
enum SignalRate {
    /// Doppler moves a low-orbit signal by up to about 25 parts per million, either way.
    static func dopplerSpan(_ frequency: Double) -> Double { frequency * 2.5e-5 * 2 }

    /// Decoders resample by themselves and only need the band to fit, and that's under twice
    /// the symbol rate. Unknown signals get room for a narrow FM channel.
    static func needed(symbolRate: Double?, baud: Double?, frequency: Double) -> Double {
        let signal: Double
        if let symbolRate, symbolRate > 0 { signal = symbolRate * 2 }
        else if let baud, baud > 0 { signal = max(50_000, baud * 4) }
        else { signal = 50_000 }
        return signal + dopplerSpan(frequency)
    }
}

/// A decoder pipeline read from the installed SatDump, so its IDs always match that version.
struct Pipeline: Identifiable, Hashable {
    let id: String
    let name: String
    let frequenciesHz: [Double]
    let samplerate: Double?
    let liveCapable: Bool
    /// Fastest symbol rate in the pipeline: a source must sample well above this to demodulate it.
    var symbolRate: Double? = nil
    /// Writes sound as it runs, so it can be heard live.
    var hasAudio = false
    /// The rate to ask for: the pipeline's own, otherwise enough for its symbols.
    var preferredRate: Double { samplerate ?? max(1_000_000, (symbolRate ?? 0) * 2.5) }
}

struct TuneSelection: Equatable {
    var pipeline: Pipeline?
    var frequencyHz: Double?
    var sampleRate: Double
    var reason: String
    /// Nothing is made for this signal, so it's only being demodulated. Worth saying, as that may not be enough.
    var noDecoder = false
}

final class PipelineCatalog {
    private(set) var pipelines: [Pipeline] = []
    private var byID: [String: Pipeline] = [:]

    private let rules: [PipelineRules.Rule]

    init(resourcesDir: URL?, updates: URL? = nil, rules: [PipelineRules.Rule]? = nil) {
        self.rules = rules ?? PipelineRules.load()
        let dir = resourcesDir?.appendingPathComponent("pipelines")
        var files = dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        // Accepted updates come last, so they replace the shipped definition of the same decoder.
        if let updates, let more = try? FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil) { files += more }
        guard !files.isEmpty else { return }
        var out: [Pipeline] = []
        for f in files where f.pathExtension == "json" {
            // SatDump's files are JSON5-ish: comments, trailing commas, and values like 1e6.
            guard let data = try? Data(contentsOf: f),
                  let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
            else { continue }
            for (id, raw) in root {
                guard let d = raw as? [String: Any], let name = d["name"] as? String else { continue }
                var freqs: [Double] = []
                for e in d["frequencies"] as? [Any] ?? [] {
                    if let pair = e as? [Any], pair.count > 1, let v = (pair[1] as? NSNumber)?.doubleValue { freqs.append(v) }
                }
                let params = d["parameters"] as? [String: Any]
                let rate = ((params?["samplerate"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue
                out.append(Pipeline(id: id, name: name, frequenciesHz: freqs, samplerate: rate, liveCapable: d["live"] != nil,
                                    symbolRate: Self.fastestSymbolRate(in: d["work"]),
                                    hasAudio: (d["work"] as? [String: Any])?["audio_wav"] != nil))
            }
        }
        byID = Dictionary(out.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        pipelines = byID.values.sorted { $0.name < $1.name }
    }

    func pipeline(_ id: String) -> Pipeline? { byID[id] }

    static func fastestSymbolRate(in value: Any?) -> Double? {
        var best: Double?
        if let d = value as? [String: Any] {
            for (k, v) in d {
                if k == "symbolrate", let n = (v as? NSNumber)?.doubleValue { best = max(best ?? 0, n) }
                else if let inner = fastestSymbolRate(in: v) { best = max(best ?? 0, inner) }
            }
        } else if let a = value as? [Any] {
            for v in a { if let inner = fastestSymbolRate(in: v) { best = max(best ?? 0, inner) } }
        }
        return best
    }

    /// The part of a decoder's name that identifies its satellite, before any words about the link.
    static func identity(ofPipelineName name: String) -> String {
        var words: [String] = []
        let stop = Set(["S-BAND", "X-BAND", "L-BAND", "UHF", "VHF", "DUMP", "LINK", "TLM", "TELEMETRY", "DB", "RAW", "DATA", "HRPT", "LRPT", "AHRPT", "DOWNLINK"])
        for w in name.uppercased().split(separator: " ") {
            if stop.contains(String(w)) { break }
            words.append(String(w))
        }
        return words.joined(separator: " ")
    }

    private static func squash(_ s: String) -> String { s.uppercased().filter { $0.isLetter || $0.isNumber } }

    /// True only if the satellite's name starts with the whole identity and it ends on a boundary:
    /// "COSMOS 2558" matches its own decoder, and "COSMOS 2400" doesn't.
    static func nameMatches(satellite: String, pipelineName: String) -> Bool {
        let id = squash(identity(ofPipelineName: pipelineName))
        guard id.count >= 4 else { return false }
        let s = satellite.uppercased()
        guard squash(s).hasPrefix(id) else { return false }
        var seen = 0
        for ch in s where ch.isLetter || ch.isNumber {
            seen += 1
            if seen == id.count { break }
        }
        // Walk to the character straight after the identity.
        var count = 0
        var after: Character?
        for ch in s {
            if count == id.count { after = ch; break }
            if ch.isLetter || ch.isNumber { count += 1 }
        }
        guard let after else { return true }
        return !(after.isLetter || after.isNumber)
    }

    private func finish(_ p: Pipeline, frequency: Double?, downlinks: [Transmitter], reason: String) -> TuneSelection {
        TuneSelection(pipeline: p, frequencyHz: frequency ?? p.frequenciesHz.first ?? downlinks.first?.downlinkHz,
                      sampleRate: p.preferredRate, reason: reason)
    }

    /// Data downlinks using AX.25, which can be read from FM audio. Other framings, like AX.100, can't.
    static func isAX25Data(_ tx: Transmitter) -> Bool {
        let mode = tx.mode.uppercased(), text = "\(tx.mode) \(tx.description)".uppercased()
        guard ["FSK", "GFSK", "GMSK"].contains(where: { mode.hasPrefix($0) }), !text.contains("AX.100") else { return false }
        return text.contains("AX.25") || text.contains("G3RUH")
    }

    /// Picks the frequency and decoder for a satellite, in this order:
    /// 1. the saved rules, using the first listed decoder that can run live;
    /// 2. a decoder named exactly after this satellite, which picks up new decoders automatically;
    /// 3. the analog demodulator for voice and tone modes;
    /// 4. no decoder, in which case the analog demodulator is still something to listen with.
    func select(for sat: Satellite) -> TuneSelection {
        let downlinks = sat.transmitters.filter { $0.active && $0.downlinkHz > 0 }

        if let rule = PipelineRules.rule(for: sat.name, in: rules) {
            let known = rule.pipelines.compactMap { byID[$0] }
            let frequency = rule.frequencyMHz.map { $0 * 1e6 }
            if let live = known.first(where: \.liveCapable) {
                return finish(live, frequency: frequency, downlinks: downlinks, reason: "Automatic")
            }
            if let slow = known.first {
                // Real but too fast to decode as it arrives, so the signal goes to file instead.
                return TuneSelection(pipeline: nil, frequencyHz: frequency ?? slow.frequenciesHz.first ?? downlinks.first?.downlinkHz,
                                     sampleRate: slow.preferredRate, reason: "\(slow.name) is too fast to decode live. Save to file works.")
            }
        }

        if let p = pipelines.first(where: { $0.liveCapable && $0.id != "analog_demod" && Self.nameMatches(satellite: sat.name, pipelineName: $0.name) }) {
            return finish(p, frequency: nil, downlinks: downlinks, reason: "Automatic")
        }

        // Voice and tone downlinks need no decoder of their own: the analog demodulator handles them.
        let analogModes = ["FM", "AM", "SSB", "USB", "LSB", "CW", "AFSK", "SSTV"]
        if let tx = sat.primaryDownlink {
            let mode = tx.mode.uppercased()
            if analogModes.contains(where: { mode.hasPrefix($0) }) || Self.isAX25Data(tx), let p = byID["analog_demod"] {
                return TuneSelection(pipeline: p, frequencyHz: tx.downlinkHz, sampleRate: p.preferredRate,
                                     reason: "Automatic: analog audio for \(tx.mode)")
            }
            return TuneSelection(pipeline: byID["analog_demod"], frequencyHz: tx.downlinkHz, sampleRate: byID["analog_demod"]?.preferredRate ?? 1_000_000,
                                 reason: byID["analog_demod"] == nil ? "No decoder yet. Save to file works." : "", noDecoder: true)
        }
        return TuneSelection(pipeline: nil, frequencyHz: nil, sampleRate: 1_000_000, reason: "No public downlink listed")
    }
}
