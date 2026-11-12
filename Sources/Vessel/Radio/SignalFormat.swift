import Foundation

/// What a signal is, in the terms operators use.
enum SignalFormat: String, CaseIterable {
    case fmVoice = "FM voice"
    case ssbVoice = "SSB voice"
    case amVoice = "AM"
    case digitalVoice = "Digital voice"
    case sstv = "SSTV"
    case ssdv = "SSDV"
    case dvb = "DVB-S2 video"
    case weatherImage = "Weather images"
    case packet = "AFSK AX.25 packet"
    case aprs = "APRS"
    case cw = "CW (Morse)"
    case fsk = "FSK telemetry"
    case psk = "BPSK/QPSK telemetry"
    case lora = "LoRa"
    case broadband = "Broadband data"
    case navigation = "Navigation signal"

    enum Group: String { case voice = "Voice", image = "Image or video", text = "Text and messaging", telemetry = "Telemetry", service = "Commercial or public service" }

    var group: Group {
        switch self {
        case .fmVoice, .ssbVoice, .amVoice, .digitalVoice: .voice
        case .sstv, .ssdv, .dvb, .weatherImage: .image
        case .packet, .aprs, .cw: .text
        case .fsk, .psk, .lora: .telemetry
        case .broadband, .navigation: .service
        }
    }

    /// What capturing it gets you here.
    var capture: String {
        switch self {
        case .fmVoice: "You can hear it through the speaker, and it's saved as audio."
        case .amVoice: "Saved as audio, which you can hear through the speaker."
        case .ssbVoice: "Saved as audio, but it sounds garbled: SSB needs a demodulator Vessel doesn't have yet."
        case .digitalVoice: "Saves the raw signal only. Vessel has no digital voice decoder."
        case .sstv: "Pictures appear in this panel and save as PNGs."
        case .ssdv: "Saves the raw signal to decode later."
        case .dvb: "Saves the raw signal only, and it's very large."
        case .weatherImage: "The decoder for this satellite makes the images."
        case .packet, .aprs: "Packets appear in this panel and save to packets.txt."
        case .cw: "Saved as audio. Vessel doesn't turn Morse into text yet."
        case .fsk, .psk, .lora: "A decoder for this satellite makes readable data if there is one. Otherwise this saves the raw signal."
        case .broadband: "This is the published band, not an exact channel. The traffic is proprietary, so at most this saves the raw signal. It often needs a dish and a downconverter."
        case .navigation: "Saves the raw signal only. Needs an L-band antenna, and the signal sits below the noise until it's processed by navigation software."
        }
    }

    /// From a listing's mode and description. Words in the description win, since the mode often
    /// only says how it's carried: SSTV listed as "FM", or APRS as "AFSK".
    static func listed(_ t: Transmitter) -> SignalFormat? {
        if t.kind == ConstellationBands.kind { return t.description.hasPrefix("Navigation") ? .navigation : .broadband }
        let mode = t.mode.uppercased()
        let text = "\(t.mode) \(t.description)".uppercased()
        if text.contains("SSTV") { return .sstv }
        if text.contains("SSDV") { return .ssdv }
        if text.contains("DVB") || text.contains("DATV") || text.contains("HAMTV") { return .dvb }
        if mode.contains("DSTAR") || mode.contains("D-STAR") || mode.contains("DMR") || mode.contains("YSF") || mode.contains("CODEC2")
            || text.contains("D-STAR") || text.contains("CODEC2") { return .digitalVoice }
        if mode == "APT" || mode == "LRPT" || mode == "HRPT" || mode == "AHRPT" { return .weatherImage }
        if text.contains("APRS") { return .aprs }
        if mode.hasPrefix("AFSK") { return .packet }
        if mode.hasPrefix("LORA") { return .lora }
        if mode.hasPrefix("USB") || mode.hasPrefix("LSB") || mode.hasPrefix("SSB") { return .ssbVoice }
        if mode.hasPrefix("CW") { return .cw }
        if mode.hasPrefix("AM") { return .amVoice }
        if mode.hasPrefix("FM") { return .fmVoice }
        if mode.hasPrefix("BPSK") || mode.hasPrefix("QPSK") || mode.hasPrefix("OQPSK") || mode.hasPrefix("DQPSK") || mode.hasPrefix("PSK") { return .psk }
        if mode.hasPrefix("FSK") || mode.hasPrefix("GFSK") || mode.hasPrefix("GMSK") || mode.hasPrefix("MSK") { return .fsk }
        return nil
    }
}

/// What the audio itself sounds like, going by a few seconds of it. Only ever a judgement, unlike a
/// decoded packet or picture, so it's described as "sounds like".
struct AudioFormatDetector {
    enum Sound: String, Equatable {
        case voice = "voice"
        case cw = "Morse"
        case afsk = "packet tones"
        case sstv = "SSTV tones"
    }

    private let rate: Double
    private let factor: Int
    private let frameLength: Int
    private let bins: [Double]
    private let cosines: [Float], sines: [Float]
    private var accumulated: Float = 0, accumulatedCount = 0
    private var frame: [Float] = []

    private struct Stat {
        let total: Float
        let peakBin: Int
        let peakShare: Float
        let afskShare: Float
        let inBand: Float
        let outBand: Float
        let level: Float // Mean of the audio, which is where AM shows keyed carrier.
    }
    private var history: [Stat] = []
    /// About 6 seconds at this frame length.
    private static let keep = 140

    init(sampleRate: Double) {
        factor = max(1, Int((sampleRate / 12000).rounded()))
        rate = sampleRate / Double(factor)
        frameLength = Int(rate * 0.0426)
        bins = stride(from: 200.0, through: 5400.0, by: 100.0).map { $0 }
        cosines = bins.map { Float(2 * cos(2 * .pi * $0 / (sampleRate / Double(max(1, Int((sampleRate / 12000).rounded())))))) }
        sines = bins.map { Float(sin(2 * .pi * $0 / (sampleRate / Double(max(1, Int((sampleRate / 12000).rounded())))))) }
        frame.reserveCapacity(frameLength)
    }

    mutating func feed(_ samples: [Float]) {
        for x in samples {
            accumulated += x
            accumulatedCount += 1
            guard accumulatedCount == factor else { continue }
            frame.append(accumulated / Float(factor))
            accumulated = 0
            accumulatedCount = 0
            if frame.count == frameLength {
                analyse()
                frame.removeAll(keepingCapacity: true)
            }
        }
    }

    private mutating func analyse() {
        var powers = [Float](repeating: 0, count: bins.count)
        let window = frameLength
        var mean: Float = 0
        for x in frame { mean += x }
        mean /= Float(window)
        // Goertzel, on a handful of frequencies: far cheaper here than a full transform.
        for b in bins.indices {
            var s1: Float = 0, s2: Float = 0
            let c = cosines[b]
            for x in frame {
                let s = (x - mean) + c * s1 - s2
                s2 = s1
                s1 = s
            }
            powers[b] = s1 * s1 + s2 * s2 - c * s1 * s2
        }
        func band(_ low: Double, _ high: Double) -> Float {
            var sum: Float = 0
            for b in bins.indices where bins[b] >= low && bins[b] <= high { sum += powers[b] }
            return sum
        }
        let inBand = band(300, 3000), outBand = band(3500, 5400)
        let total = powers.reduce(0, +)
        var peak = 0
        for b in bins.indices where powers[b] > powers[peak] { peak = b }
        // A tone's power falls on neighbours too, as it rarely sits on a frequency exactly.
        let near = powers[max(0, peak - 1)...min(bins.count - 1, peak + 1)].reduce(0, +)
        let afsk = band(1000, 1400) + band(2000, 2400)
        history.append(Stat(total: total, peakBin: peak, peakShare: near / (total + 1e-9), afskShare: afsk / (total + 1e-9),
                            inBand: inBand, outBand: outBand, level: abs(mean)))
        if history.count > Self.keep { history.removeFirst(history.count - Self.keep) }
    }

    private func transitions(_ on: [Bool]) -> (count: Int, longestRun: Int, share: Double) {
        var changes = 0, run = 0, longest = 0
        for (a, b) in zip(on, on.dropFirst()) {
            if a != b { changes += 1; run = 0 } else { run += 1; longest = max(longest, run) }
        }
        return (changes, longest, Double(on.filter { $0 }.count) / Double(max(on.count, 1)))
    }

    /// Nil until there's enough to go on, or if it doesn't clearly sound like anything.
    var sound: Sound? {
        guard history.count >= 70 else { return nil }
        let loudest = history.map(\.total).max() ?? 0
        let loudLevel = history.map(\.level).max() ?? 0

        // Keyed: on and off in Morse-like beats, as a steady tone or as a level on an AM carrier.
        // Off has to be clearly lower than on, which FM noise never manages.
        let keyedTone = history.map { $0.peakShare > 0.6 && $0.total > loudest * 0.25 }
        let peakBins = zip(history, keyedTone).filter { $0.1 }.map(\.0.peakBin)
        if let first = peakBins.first, peakBins.allSatisfy({ abs($0 - first) <= 1 }) {
            let t = transitions(keyedTone)
            if t.count >= 6, t.share > 0.1, t.share < 0.85, t.longestRun < 60 { return .cw }
        }
        if loudLevel > 0.1 {
            // Clearly on or clearly off, with little between. Noise only ever wanders.
            let settled = history.filter { $0.level > loudLevel * 0.6 || $0.level < loudLevel * 0.2 }.count
            let keyedLevel = history.map { $0.level > loudLevel * 0.5 }
            let t = transitions(keyedLevel)
            if Double(settled) / Double(history.count) > 0.85, t.count >= 6, t.share > 0.1, t.share < 0.85, t.longestRun < 60 { return .cw }
        }

        let active = history.filter { $0.total > loudest * 0.05 }
        guard active.count >= 40, loudest > 0 else { return nil }
        let share = { (test: (Stat) -> Bool) in Double(active.filter(test).count) / Double(active.count) }

        // Both packet tones at once within a frame, and little else.
        if share({ $0.afskShare > 0.6 && $0.peakShare < 0.85 }) > 0.7 { return .afsk }

        // Single tones between 1100 and 2300 Hz that keep moving: a picture being scanned.
        let inRange = active.filter { $0.peakShare > 0.5 && bins[$0.peakBin] >= 1100 && bins[$0.peakBin] <= 2300 }
        if Double(inRange.count) / Double(active.count) > 0.75, Set(inRange.map(\.peakBin)).count >= 3 { return .sstv }

        // Speech: mostly below 3 kHz, not tonal, and rising and falling with the syllables.
        let lowHeavy = share { $0.inBand > $0.outBand * 6 }
        let tonal = share { $0.peakShare > 0.7 }
        let levels = history.map { $0.total.squareRoot() }
        let meanLevel = levels.reduce(0, +) / Float(levels.count)
        let spread = (levels.map { ($0 - meanLevel) * ($0 - meanLevel) }.reduce(0, +) / Float(levels.count)).squareRoot()
        if lowHeavy > 0.7, tonal < 0.6, spread > meanLevel * 0.35 { return .voice }
        return nil
    }
}

/// Listens to the captured audio for what it sounds like.
@MainActor
final class FormatMonitor: ObservableObject {
    @Published private(set) var sound: AudioFormatDetector.Sound?
    private let worker = Worker()
    private var folder: URL?

    func follow(_ next: URL?) {
        guard next != folder else { return }
        folder = next
        sound = nil
        worker.follow(next) { [weak self] heard in
            Task { @MainActor in
                guard let self, self.sound != heard else { return }
                self.sound = heard
            }
        }
    }

    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "Vessel.format")
        private var timer: DispatchSourceTimer?
        private var tail: WavTail?
        private var detector: AudioFormatDetector?
        private var send: ((AudioFormatDetector.Sound?) -> Void)?

        func follow(_ folder: URL?, send: @escaping (AudioFormatDetector.Sound?) -> Void) {
            queue.async { [self] in
                timer?.cancel(); timer = nil
                tail = nil; detector = nil
                self.send = send
                guard let folder else { return }
                tail = WavTail(folder: folder)
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: 0.5)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }

        private func tick() {
            guard let tail, let samples = tail.read(), let format = tail.format else { return }
            if detector == nil { detector = AudioFormatDetector(sampleRate: format.sampleRate) }
            detector?.feed(samples)
            send?(detector?.sound)
        }
    }
}
