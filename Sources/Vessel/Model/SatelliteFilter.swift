import Foundation

enum TriFilter: String, CaseIterable, Identifiable {
    case any = "Any", yes = "Yes", no = "No"
    var id: String { rawValue }

    func allows(_ value: Bool?) -> Bool {
        switch self {
        case .any: true
        case .yes: value == true
        case .no: value == false
        }
    }
}

/// How people can use a satellite to talk, going by its active public uplinks in the amateur-satellite bands.
enum CommunicationKind: String, CaseIterable, Identifiable {
    case fmRepeater = "FM repeater"
    case iss = "ISS (ARISS)"
    case linear = "Linear (SSB/CW)"
    case digital = "Digital / packet"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .fmRepeater: "One conversation at a time on FM voice. A handheld radio is enough, so it's the best place to start."
        case .iss: "The space station's amateur radio station. It often runs an FM voice repeater anyone can use during a pass."
        case .linear: "Many people at once on SSB or CW. Needs a multi-mode base station radio."
        case .digital: "Text, APRS positions and messages rather than voice."
        }
    }

    static let issNorad = 25544

    /// What a listing's mode says about talking through it, for a satellite that has an uplink at all.
    /// Finding them is wider than transmitting to them, which still has to pass `UplinkPolicy`.
    static func listed(mode: String?) -> Set<CommunicationKind> {
        let labels = Set(SignalLabel.modes(in: mode ?? "").map(\.text))
        var kinds = Set<CommunicationKind>()
        if labels.contains("FM") { kinds.insert(.fmRepeater) }
        if !labels.isDisjoint(with: ["SSB", "USB", "LSB", "CW"]) { kinds.insert(.linear) }
        if !labels.isDisjoint(with: ["APRS", "AFSK", "FSK", "GFSK", "GMSK", "MSK", "BPSK", "QPSK", "JAS"]) { kinds.insert(.digital) }
        return kinds
    }

    static func of(norad: Int, uplinks: [Uplink]) -> Set<CommunicationKind> {
        var kinds = Set<CommunicationKind>()
        for u in uplinks {
            if u.isLinear || u.modes.contains(.cw) { kinds.insert(.linear) }
            else if u.modes.contains(.fmVoice) { kinds.insert(.fmRepeater) }
            if u.modes.contains(where: \.isPacket) { kinds.insert(.digital) }
        }
        if norad == issNorad, !uplinks.isEmpty { kinds.insert(.iss) }
        return kinds
    }
}

/// The options behind the Filters button.
struct SatelliteFilter: Equatable {
    var year: Int?
    /// By the name shown in the menu.
    var country: String?
    var category: SatCategory?
    var encryption = TriFilter.any
    var frequency = TriFilter.any
    var communication: CommunicationKind?
    var media: MediaKind?
    /// Only what the current receiver can tune to.
    var withinReceiver = false
    /// Only the satellites of a group being shown alone.
    var onlyNorads: Set<Int>?

    var activeCount: Int {
        [year != nil, country != nil, category != nil, encryption != .any, frequency != .any, communication != nil, media != nil, withinReceiver, onlyNorads != nil].filter { $0 }.count
    }
    var isActive: Bool { activeCount > 0 }

    /// Partly encrypted counts as encrypted, because something on it is. Where nothing is
    /// known, a satellite only shows under Any rather than being guessed either way.
    static func isEncrypted(_ state: EncryptionInfo.State) -> Bool? {
        switch state {
        case .yes, .partly: true
        case .no: false
        case .unknown: nil
        }
    }

    func matches(launchYear: Int?, encryption state: EncryptionInfo.State, hasFrequency: Bool, country name: String = "", category satCategory: SatCategory = .unknown,
                 communication kinds: Set<CommunicationKind> = [], media mediaKinds: Set<MediaKind> = [], reachable: Bool = true) -> Bool {
        if let year, launchYear != year { return false }
        if let country, name != country { return false }
        if let category, satCategory != category { return false }
        if let communication, !kinds.contains(communication) { return false }
        if let media, !mediaKinds.contains(media) { return false }
        if withinReceiver, !reachable { return false }
        return encryption.allows(Self.isEncrypted(state)) && frequency.allows(hasFrequency)
    }
}
