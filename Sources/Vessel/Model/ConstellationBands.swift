import Foundation

/// Whole constellations whose downlink bands are public, even though no list gives them satellite by
/// satellite. These say where a signal is. Broadband ones are proprietary and can't be decoded.
enum ConstellationBands {
    static let kind = "Published band"

    private struct Band {
        let name: String
        let lowHz: Double
        let highHz: Double?
        let navigation: Bool

        init(_ name: String, _ lowMHz: Double, _ highMHz: Double? = nil, navigation: Bool = false) {
            self.name = name
            lowHz = lowMHz * 1e6
            highHz = highMHz.map { $0 * 1e6 }
            self.navigation = navigation
        }

        var transmitter: Transmitter {
            // A band tunes to its middle, and a navigation signal to its own frequency.
            let tuned = highHz.map { (lowHz + $0) / 2 } ?? lowHz
            let label: String
            if let highHz {
                label = "\(name) \(Self.range(lowHz, highHz))"
            } else {
                label = name
            }
            return Transmitter(description: navigation ? "Navigation signal, published" : "Downlink band, published",
                               downlinkHz: tuned, mode: label, active: true, baud: nil, kind: kind)
        }

        private static func range(_ low: Double, _ high: Double) -> String {
            high >= 1e10 ? String(format: "%.1f–%.1f GHz", low / 1e9, high / 1e9) : String(format: "%g–%g MHz", low / 1e6, high / 1e6)
        }
    }

    private static let table: [(pattern: String, bands: [Band])] = [
        // Confirmed for Starlink by ETH Zurich's Satellite Database.
        ("^STARLINK", [Band("Ku-band", 10_700, 12_700)]),
        ("^ONEWEB", [Band("Ku-band", 10_700, 12_700)]),
        ("^KUIPER", [Band("Ka-band", 17_700, 20_200)]),
        ("^O3B", [Band("Ka-band", 17_800, 19_300)]),
        ("^IRIDIUM", [Band("L-band", 1_616, 1_626.5)]),
        ("^GLOBALSTAR", [Band("S-band", 2_483.5, 2_500)]),
        ("^ORBCOMM", [Band("VHF", 137, 138)]),
        ("^(NAVSTAR|GPS )", [Band("GPS L1", 1_575.42, navigation: true), Band("GPS L2", 1_227.60, navigation: true), Band("GPS L5", 1_176.45, navigation: true)]),
        ("^(GSAT0|GALILEO)", [Band("Galileo E1", 1_575.42, navigation: true), Band("Galileo E5a", 1_176.45, navigation: true), Band("Galileo E5b", 1_207.14, navigation: true), Band("Galileo E6", 1_278.75, navigation: true)]),
        ("^BEIDOU", [Band("BeiDou B1I", 1_561.098, navigation: true), Band("BeiDou B1C", 1_575.42, navigation: true), Band("BeiDou B2a", 1_176.45, navigation: true), Band("BeiDou B3I", 1_268.52, navigation: true)]),
        // Military Cosmos satellites share the name, but only GLONASS carry a slot number like "(702K)".
        (#"^COSMOS \d+ \(\d{3}[A-Z]?\)$"#, [Band("GLONASS G1", 1_602, navigation: true), Band("GLONASS G2", 1_246, navigation: true)]),
        ("^QZS", [Band("QZSS L1", 1_575.42, navigation: true), Band("QZSS L5", 1_176.45, navigation: true)]),
        ("^IRNSS", [Band("NavIC L5", 1_176.45, navigation: true), Band("NavIC S", 2_492.028, navigation: true)]),
    ]

    static func transmitters(forName name: String) -> [Transmitter] {
        let upper = name.uppercased()
        for entry in table where upper.range(of: entry.pattern, options: .regularExpression) != nil {
            return entry.bands.map(\.transmitter)
        }
        return []
    }
}
