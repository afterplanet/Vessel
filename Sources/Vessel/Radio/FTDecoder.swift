import Foundation
import CFT8

struct FTMessage: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let mode: String
    let text: String
    /// Audio frequency of its lowest tone.
    let audioHz: Double
    /// Seconds from the slot boundary, which shows how far off a clock is.
    let offset: Double
    let strength: Double

    static func == (a: FTMessage, b: FTMessage) -> Bool { a.id == b.id }
}

/// FT8 and FT4 decoding through ft8_lib.
enum FTDecoder {
    private final class Collector { var found: [(String, Float, Float, Float)] = [] }

    /// One slot of audio, starting at about the slot boundary.
    static func decode(_ samples: [Float], rate: Int, ft4: Bool, at time: Date = Date()) -> [FTMessage] {
        let box = Collector()
        let context = Unmanaged.passUnretained(box).toOpaque()
        samples.withUnsafeBufferPointer { p in
            _ = cft8_decode(p.baseAddress, Int32(p.count), Int32(rate), ft4 ? 1 : 0, 200, 3000, { text, hz, dt, snr, ctx in
                guard let text, let ctx else { return }
                Unmanaged<Collector>.fromOpaque(ctx).takeUnretainedValue().found.append((String(cString: text), hz, dt, snr))
            }, context)
        }
        return box.found.map { FTMessage(time: time, mode: ft4 ? "FT4" : "FT8", text: $0.0, audioHz: Double($0.1), offset: Double($0.2), strength: Double($0.3)) }
    }
}
