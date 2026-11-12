import Foundation

/// Satellites that send pictures or video down, rather than voice or data.
enum MediaKind: String, CaseIterable, Identifiable {
    case sstv = "SSTV"
    case ssdv = "SSDV"
    case datv = "DATV"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .sstv: "Pictures sent as audio tones over FM. A simple radio can receive them, and they're often sent for special events."
        case .ssdv: "Pictures sent as data packets, so a lost packet only loses part of the image."
        case .datv: "Live digital video, often DVB-S or DVB-S2. Takes wide bandwidth and usually a dish on 2.4 GHz or above."
        }
    }

    /// AMSAT labels its modes "ISS_[SSTV]", and calls DATV by its standard too.
    static func fromAMSATMode(_ name: String) -> MediaKind? {
        guard let mode = name.components(separatedBy: "_[").last?.replacingOccurrences(of: "]", with: "").uppercased() else { return nil }
        switch mode {
        case "SSTV": return .sstv
        case "SSDV": return .ssdv
        case "DATV", "DVB-S", "DVB-S2": return .datv
        default: return nil
        }
    }
}

/// One picture or video downlink.
struct MediaSignal: Hashable, Identifiable {
    let kind: MediaKind
    let hz: Double
    /// The picture format, where the listing names one: "Robot 36", "PD120".
    let format: String?
    let baud: Double?
    var id: String { "\(kind.rawValue)-\(Int(hz))" }

    var title: String { [kind.rawValue, format].compactMap { $0 }.joined(separator: " ") }

    /// Amateur-satellite downlink bands. DVB-S2 is also how commercial imaging satellites send
    /// their data home, and that isn't video anyone can tune in to.
    private static let amateurBands: [ClosedRange<Double>] = [
        2_400e6...2_450e6, 5_830e6...5_850e6, 10_450e6...10_500e6, 24_000e6...24_050e6,
    ]

    static func kind(of t: Transmitter) -> MediaKind? {
        guard t.active, t.downlinkHz > 0 else { return nil }
        let text = "\(t.mode) \(t.description)".uppercased()
        if text.contains("SSTV") { return .sstv }
        if text.contains("SSDV") { return .ssdv }
        if text.contains("DATV") || text.contains("HAMTV") { return .datv }
        if text.contains("DVB"), amateurBands.contains(where: { $0.contains(t.downlinkHz) }) { return .datv }
        return nil
    }

    static func format(in description: String) -> String? {
        let patterns = [#"(?i)\brobot[ -]?\d+"#, #"(?i)\bPD[ -]?\d+"#, #"(?i)\bmartin[ -]?M?\d"#, #"(?i)\bscottie[ -]?S?\d"#]
        for p in patterns {
            if let r = description.range(of: p, options: .regularExpression) { return String(description[r]) }
        }
        return nil
    }

    /// One entry per frequency, since listings often repeat a downlink for each picture format.
    static func signals(in transmitters: [Transmitter]) -> [MediaSignal] {
        var seen = Set<String>()
        return transmitters.compactMap { t -> MediaSignal? in
            guard let kind = kind(of: t) else { return nil }
            let s = MediaSignal(kind: kind, hz: t.downlinkHz, format: kind == .sstv ? format(in: t.description) : nil, baud: t.baud)
            return seen.insert(s.id).inserted ? s : nil
        }
    }

    /// Enough to save it when no decoder sets the rate. Nil leaves it to the decoder.
    var neededSampleRate: Double? {
        switch kind {
        case .sstv: nil
        case .ssdv: max(250_000, (baud ?? 0) * 10)
        case .datv: max(2_500_000, (baud ?? 0) * 2.5)
        }
    }

    var captureAdvice: String {
        switch kind {
        case .sstv: "Received as FM audio, and pictures appear here as they come in, saved as PNGs beside the WAV. Through the speaker it sounds like warbling tones."
        case .ssdv: "Vessel has no SSDV decoder yet, so this saves the raw signal to decode later."
        case .datv: "Too wide to decode here, so this saves the raw signal, and the file grows very fast. It needs a source that reaches this frequency."
        }
    }
}
