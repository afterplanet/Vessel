import Foundation

enum TxMode: String, CaseIterable, Identifiable {
    case fmVoice = "FM voice"
    case ssbVoice = "SSB voice"
    case cw = "CW"
    case aprs = "APRS"
    case aprsPosition = "APRS position"
    case packet1200 = "Packet 1200"
    case packet9600 = "Packet 9600"
    case psk31 = "PSK31"
    case rtty = "RTTY"
    case ft8 = "FT8"
    case ft4 = "FT4"
    var id: String { rawValue }
    var isVoice: Bool { self == .fmVoice || self == .ssbVoice }
    var usesMessage: Bool { !isVoice && self != .aprsPosition }
    var isPacket: Bool { self == .aprs || self == .aprsPosition || self == .packet1200 || self == .packet9600 }

    /// FT8 and FT4 stations transmit on fixed UTC boundaries, in seconds.
    var slotSeconds: Double? {
        switch self {
        case .ft8: 15
        case .ft4: 7.5
        default: nil
        }
    }

    /// Audio frequency at the centre of the signal. On SSB this offsets the RF from the radio's dial.
    var audioCentreHz: Double {
        switch self {
        case .ssbVoice: 1500
        case .cw: 700
        case .psk31: 1000
        case .rtty: 2210
        case .ft8: 1500 + 3.5 * 6.25
        case .ft4: 1500 + 1.5 * 20.833
        default: 0
        }
    }

    /// Half the occupied bandwidth, used to keep the whole signal inside a transponder's passband.
    var halfBandwidthHz: Double {
        switch self {
        case .ssbVoice: 1500
        case .cw: 100
        case .psk31: 50
        case .rtty: 200
        case .ft8: 40
        case .ft4: 60
        default: 0
        }
    }
}

/// A transmit target. Instances exist only for uplinks that passed `UplinkPolicy`, and the
/// frequency is always derived from one, so the app has no way to transmit anywhere else.
struct Uplink: Identifiable, Hashable {
    let id: String
    let description: String
    let lowHz: Double
    let highHz: Double
    let modeName: String
    let downlinkLowHz: Double
    let downlinkHighHz: Double
    let downlinkMode: String
    let inverted: Bool
    let ctcssHz: Double?
    let modes: [TxMode]

    var isLinear: Bool { highHz > lowHz }
    var isUSB: Bool { modeName.uppercased() == "USB" }

    /// Where the signal itself lands, kept far enough inside the passband that all of it fits.
    func signalHz(position: Double, mode: TxMode?) -> Double {
        let nominal = nominalUplink(position: position)
        guard isLinear else { return nominal }
        let half = min(mode?.halfBandwidthHz ?? 0, (highHz - lowHz) / 2)
        return min(highHz - half, max(lowHz + half, nominal))
    }

    /// The radio's dial for that signal. On SSB the audio tone adds to the dial or subtracts from it.
    func dialHz(position: Double, mode: TxMode?) -> Double {
        let signal = signalHz(position: position, mode: mode)
        guard isLinear, let mode else { return signal }
        return isUSB ? signal - mode.audioCentreHz : signal + mode.audioCentreHz
    }

    /// The downlink that corresponds to the signal's place in the passband.
    func downlinkHz(position: Double, mode: TxMode?) -> Double {
        guard isLinear else { return nominalDownlink(position: position) }
        return nominalDownlink(position: (signalHz(position: position, mode: mode) - lowHz) / (highHz - lowHz))
    }

    /// `position` is 0...1 across the passband, and is ignored on a single-frequency uplink.
    func nominalUplink(position: Double) -> Double {
        lowHz + (highHz - lowHz) * min(1, max(0, position))
    }

    func nominalDownlink(position: Double) -> Double {
        let p = min(1, max(0, position))
        let span = downlinkHighHz - downlinkLowHz
        return inverted ? downlinkHighHz - span * p : downlinkLowHz + span * p
    }
}

enum Eligibility: Equatable {
    case allowed
    case notAmateur, inactive, outsideSubBand, flaggedViolation, uncoordinated, notPublic, noUplink

    var reason: String {
        switch self {
        case .allowed: "Open to amateurs"
        case .notAmateur: "Not an amateur service"
        case .inactive: "Not active"
        case .outsideSubBand: "Outside the amateur-satellite bands"
        case .flaggedViolation: "Flagged for a frequency violation"
        case .uncoordinated: "Not coordinated with IARU"
        case .notPublic: "Command or telemetry link, not for public use"
        case .noUplink: "No uplink listed"
        }
    }

    /// A sentence on what the reason means, for the popover beside a refused uplink.
    var explanation: String {
        switch self {
        case .allowed: "It's open to licensed amateurs."
        case .notAmateur: "It isn't an amateur service, so it isn't yours to transmit to."
        case .inactive: "SatNOGS lists this transmitter as no longer working, so nothing would answer."
        case .outsideSubBand: "Its frequency is outside the bands set aside for amateur satellites."
        case .flaggedViolation: "SatNOGS flags it for using frequencies it shouldn't, so joining in would break the rules too."
        case .uncoordinated: "Its frequencies were never agreed with IARU, which coordinates amateur satellite frequencies."
        case .notPublic: "It's for commanding the spacecraft or its telemetry, which belongs to its operators."
        case .noUplink: "No uplink frequency is listed."
        }
    }
}

enum UplinkPolicy {
    /// Amateur-satellite sub-bands, in Hz.
    static let subBands: [ClosedRange<Double>] = [
        145_800_000...146_000_000,
        435_000_000...438_000_000,
        1_260_000_000...1_270_000_000,
        2_400_000_000...2_450_000_000,
    ]

    private static let blocked = #"(?i)command|telecommand|\btc\b|dtmf|telemetry|\btlm\b|beacon|ping|store|ssdv|camera"#
    private static let publicUse = #"(?i)repeater|digipeater|transponder|voice|aprs|linear|fm to dsb|fm transceiver|^mode [a-z]/[a-z] fm$"#

    /// `unknownServiceOK` is for finding satellites only. Transmitting always needs a listed amateur service.
    static func evaluate(_ t: Transmitter, unknownServiceOK: Bool = false) -> Eligibility {
        guard let low = t.uplinkLowHz, low > 0 else { return .noUplink }
        let high = max(t.uplinkHighHz ?? low, low)
        guard t.service == "Amateur" || (unknownServiceOK && t.service == "Unknown") else { return .notAmateur }
        guard t.active else { return .inactive }
        guard !t.frequencyViolation else { return .flaggedViolation }
        let c = t.coordination.lowercased()
        guard !c.contains("declined"), !c.contains("uncoordinated") else { return .uncoordinated }
        guard subBands.contains(where: { $0.contains(low) && $0.contains(high) }) else { return .outsideSubBand }
        if t.description.range(of: blocked, options: .regularExpression) != nil { return .notPublic }
        let isTransponder = t.kind.lowercased() == "transponder"
        guard isTransponder || t.description.range(of: publicUse, options: .regularExpression) != nil else { return .notPublic }
        return .allowed
    }

    /// Every rule an uplink fails, not only the first, so the full picture can be shown.
    static func problems(_ t: Transmitter) -> [Eligibility] {
        guard let low = t.uplinkLowHz, low > 0 else { return [.noUplink] }
        let high = max(t.uplinkHighHz ?? low, low)
        var out: [Eligibility] = []
        if t.service != "Amateur" { out.append(.notAmateur) }
        if !t.active { out.append(.inactive) }
        if t.frequencyViolation { out.append(.flaggedViolation) }
        let c = t.coordination.lowercased()
        if c.contains("declined") || c.contains("uncoordinated") { out.append(.uncoordinated) }
        if !subBands.contains(where: { $0.contains(low) && $0.contains(high) }) { out.append(.outsideSubBand) }
        let isTransponder = t.kind.lowercased() == "transponder"
        if t.description.range(of: blocked, options: .regularExpression) != nil
            || !(isTransponder || t.description.range(of: publicUse, options: .regularExpression) != nil) { out.append(.notPublic) }
        return out
    }

    /// Uplinks that are listed but can't be used, each with every reason why.
    static func refused(for sat: Satellite) -> [(transmitter: Transmitter, reasons: [Eligibility])] {
        sat.transmitters.compactMap { t in
            guard t.uplinkLowHz.map({ $0 > 0 }) == true, evaluate(t) != .allowed else { return nil }
            return (t, problems(t))
        }
    }

    static func uplinks(for sat: Satellite) -> [Uplink] {
        sat.transmitters.compactMap { make($0) }
    }

    /// For the Communication filter. SatNOGS leaves the service blank on well-known amateur satellites like
    /// SO-50, FO-29 and QO-100, so these can include some that `uplinks(for:)` won't transmit to.
    static func listedUplinks(for sat: Satellite) -> [Uplink] {
        sat.transmitters.compactMap { make($0, unknownServiceOK: true) }
    }

    static func make(_ t: Transmitter, unknownServiceOK: Bool = false) -> Uplink? {
        guard evaluate(t, unknownServiceOK: unknownServiceOK) == .allowed, let low = t.uplinkLowHz else { return nil }
        let high = max(t.uplinkHighHz ?? low, low)
        return Uplink(id: "\(Int(low))-\(Int(high))-\(t.description)", description: t.description,
                      lowHz: low, highHz: high, modeName: t.uplinkMode ?? t.mode,
                      downlinkLowHz: t.downlinkHz, downlinkHighHz: max(t.downlinkHighHz ?? t.downlinkHz, t.downlinkHz),
                      downlinkMode: t.mode, inverted: t.inverted, ctcssHz: ctcss(in: t.description),
                      modes: modes(t, linear: high > low))
    }

    static func modes(_ t: Transmitter, linear: Bool) -> [TxMode] {
        let m = (t.uplinkMode ?? t.mode).uppercased()
        let d = t.description.uppercased()
        if linear, m == "USB" || m == "LSB" { return [.ssbVoice, .cw, .psk31, .rtty, .ft8, .ft4] }
        if m == "CW" { return [.cw] }
        if m.hasPrefix("FM") {
            return d.contains("(A)FSK") || d.contains("APRS") ? [.fmVoice, .aprs, .aprsPosition, .packet1200] : [.fmVoice]
        }
        if m == "AFSK", d.contains("DIGIPEATER") || d.contains("APRS") { return [.aprs, .aprsPosition, .packet1200] }
        // 9600 only where the listing says AX.25: Mobitex, AX.100 and Skylink use other framing.
        if m.hasPrefix("FSK") || m.hasPrefix("GFSK") || m.hasPrefix("GMSK"), !m.contains("AX.100") {
            let framed = d.contains("AX.25") || d.contains("G3RUH")
            let fast = t.baud == 9600 || d.contains("9K6")
            if framed, fast, d.contains("DIGIPEATER") || d.contains("REPEATER") { return [.packet9600] }
        }
        return []
    }

    /// "CTCSS 67.0 Hz" or "PL 88.5Hz", but not "no CTCSS any longer".
    static func ctcss(in description: String) -> Double? {
        let d = description
        if d.range(of: #"(?i)\bno\s+(ctcss|pl)\b"#, options: .regularExpression) != nil { return nil }
        let patterns = [#"(?i)(?:ctcss|pl)\s*(\d{2,3}(?:\.\d)?)"#, #"(?i)(\d{2,3}\.\d)\s*(?:hz\s*)?(?:ctcss|pl)\b"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: d, range: NSRange(d.startIndex..., in: d)),
                  let r = Range(m.range(at: 1), in: d) else { continue }
            return Double(d[r])
        }
        return nil
    }
}

/// Four-character grid locator, the position field in FT8 and FT4 messages.
enum Maidenhead {
    static func locator(lat: Double, lon: Double) -> String {
        let x = min(359.999, max(0, lon + 180)), y = min(179.999, max(0, lat + 90))
        let a = UnicodeScalar(65 + UInt8(x / 20)), b = UnicodeScalar(65 + UInt8(y / 10))
        return "\(Character(a))\(Character(b))\(Int(x / 2) % 10)\(Int(y) % 10)"
    }
}

enum Doppler {
    static let c = 299_792.458 // km/s

    /// The frequency to transmit so the satellite hears `nominal`. `rangeRate` is km/s, positive when receding.
    static func uplink(_ nominal: Double, rangeRate rr: Double) -> Double { nominal * (1 + rr / c) }
    /// The frequency a satellite transmitting `nominal` arrives at on the ground.
    static func downlink(_ nominal: Double, rangeRate rr: Double) -> Double { nominal * (1 - rr / c) }
}

/// Amateur callsign, with an optional SSID: `W1AW`, `VU2ABC`, `9V1XY-7`.
enum Callsign {
    static func isValid(_ s: String) -> Bool {
        s.range(of: #"^[A-Z0-9]{1,3}[0-9][A-Z]{1,4}(-[0-9]{1,2})?$"#, options: .regularExpression) != nil
            && s.contains(where: \.isLetter)
    }
}

/// Every condition that has to hold for the radio to key, and to stay keyed.
struct TxChecks: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let pass: Bool
        let detail: String
    }

    var callsign: String
    var licenceConfirmed: Bool
    var sourceKind: SDRSource.Kind
    var station: Station?
    var radioConnected: Bool
    var uplink: Uplink?
    var mode: TxMode?
    var elevation: Double?
    var minElevation: Double
    var elementAgeDays: Double?
    var audioReady: Bool
    var audioDetail: String? = nil

    var items: [Item] {
        var out = [
            Item(id: "Callsign", pass: Callsign.isValid(callsign), detail: callsign.isEmpty ? "Enter your callsign" : callsign),
            Item(id: "Licence", pass: licenceConfirmed, detail: "Confirm you are licensed for this band"),
            Item(id: "Local radio", pass: sourceKind == .usb, detail: sourceKind == .usb ? "Listener source is local" : "On the Receive tab, choose a USB source instead of a network one"),
            Item(id: "Your location", pass: station != nil && station?.fromSpyHost != true, detail: station.map { $0.fromSpyHost ? "A spy host is not your location" : $0.name } ?? "Type your location"),
            Item(id: "Radio", pass: radioConnected, detail: radioConnected ? "Connected, uplink confirmed" : "Connect the radio"),
            Item(id: "Uplink", pass: uplink != nil && mode != nil && uplink?.modes.contains(mode!) == true, detail: uplink == nil ? "No public uplink" : mode?.rawValue ?? "This uplink's mode isn't supported yet"),
        ]
        if let e = elevation {
            out.append(Item(id: "In view", pass: e >= minElevation, detail: String(format: "%.1f° (min %.0f°)", e, minElevation)))
        } else {
            out.append(Item(id: "In view", pass: false, detail: "Position unknown"))
        }
        if let a = elementAgeDays {
            out.append(Item(id: "Orbit data", pass: a < TxChecks.maxElementAgeDays, detail: String(format: "%.1f days old", a)))
        } else {
            out.append(Item(id: "Orbit data", pass: false, detail: "No orbit data"))
        }
        out.append(Item(id: "Audio", pass: audioReady, detail: audioReady ? "Ready" : audioDetail ?? "Choose an audio output and message"))
        return out
    }

    static let maxElementAgeDays = 7.0
    var allPass: Bool { items.allSatisfy(\.pass) }
    var firstFailure: Item? { items.first { !$0.pass } }
}
