import Foundation

/// Two small errors that add up to missing a narrow signal: the receiver's own clock being off
/// (parts per million, the same on every frequency), and a satellite not being quite where it's listed.
enum FrequencyCorrection {
    /// Sources whose driver applies a ppm correction itself.
    static let nativeSources: Set<String> = ["rtlsdr", "rtltcp"]

    /// What to ask a receiver for so that it lands on `hz`, when its clock runs `ppm` fast.
    /// This follows the RTL-SDR convention for the sign.
    static func dial(_ hz: Double, ppm: Double) -> Double { hz / (1 + ppm * 1e-6) }

    /// How far off a signal looks, in Hz, on a receiver with this error.
    static func error(at hz: Double, ppm: Double) -> Double { hz * ppm * 1e-6 }

    /// One saved offset per satellite and listed frequency, to the nearest kHz.
    static func key(norad: Int, hz: Double) -> String { "\(norad)-\(Int((hz / 1000).rounded()))" }

    static func arguments(source: String, ppm: Double) -> [String] {
        // These drivers take whole numbers only. Any fraction left over is made up on the dial.
        guard ppm.rounded() != 0, nativeSources.contains(source) else { return [] }
        return ["--ppm_correction", String(Int(ppm.rounded()))]
    }

    /// The frequency to request: unchanged where the driver corrects, shifted where it can't.
    static func requested(_ hz: Double, source: String, ppm: Double) -> Double {
        nativeSources.contains(source) ? dial(hz, ppm: ppm - ppm.rounded()) : dial(hz, ppm: ppm)
    }
}
