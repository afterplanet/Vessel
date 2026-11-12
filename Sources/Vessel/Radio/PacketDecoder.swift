import Foundation

/// One AX.25 frame that passed its checksum.
struct AX25Frame: Equatable {
    let destination: String
    let source: String
    let path: [String]
    let info: [UInt8]
    /// The whole frame, without its checksum, which is what telemetry formats read.
    var bytes: [UInt8] = []

    var infoText: String {
        String(decoding: info.map { (0x20...0x7E).contains($0) ? $0 : 0x2E }, as: UTF8.self)
    }

    /// Raw telemetry rather than text, which reads better as hex for tools like FoxTelem.
    var isBinary: Bool {
        !info.isEmpty && info.contains { !(0x20...0x7E).contains($0) && $0 != 0x0D && $0 != 0x0A }
    }
    var hexText: String { info.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Nil unless it's a well-formed frame: noise that slips past the checksum rarely has valid callsigns too.
    static func parse(_ frame: [UInt8]) -> AX25Frame? {
        guard frame.count >= 18 else { return nil }
        let body = Array(frame.dropLast(2))
        let fcs = UInt16(frame[frame.count - 2]) | UInt16(frame[frame.count - 1]) << 8
        guard AX25.crc(body) == fcs else { return nil }
        var calls: [String] = []
        var at = 0
        while true {
            guard at + 7 <= body.count, calls.count < 10 else { return nil }
            var call = ""
            for byte in body[at..<(at + 6)] {
                guard byte & 1 == 0 else { return nil }
                let c = byte >> 1
                let letterOrDigit = (0x30...0x39).contains(c) || (0x41...0x5A).contains(c)
                guard letterOrDigit || c == 0x20 else { return nil }
                if c != 0x20 { call.append(Character(UnicodeScalar(c))) }
            }
            guard !call.isEmpty else { return nil }
            let ssid = (body[at + 6] >> 1) & 0x0F
            calls.append(ssid == 0 ? call : "\(call)-\(ssid)")
            let last = body[at + 6] & 1 == 1
            at += 7
            if last { break }
        }
        guard calls.count >= 2, at + 1 <= body.count else { return nil }
        // Control, then a protocol byte on the frames that carry text.
        let control = body[at]
        var start = at + 1
        if control & 0xEF == 0x03 || control & 0x01 == 0 { start += 1 }
        return AX25Frame(destination: calls[0], source: calls[1], path: Array(calls.dropFirst(2)), info: start <= body.count ? Array(body[start...]) : [], bytes: body)
    }
}

/// Turns recovered bits into frames: flags, bit stuffing, and the checksum.
struct HDLCReceiver {
    private var shift: UInt8 = 0
    private var inFrame = false
    private var ones = 0
    private var bitCount = 0
    private var byte: UInt8 = 0
    private var bytes: [UInt8] = []

    /// Returns a frame if this bit completed one that checks out.
    mutating func push(_ bit: Bool) -> AX25Frame? {
        shift = shift >> 1 | (bit ? 0x80 : 0)
        if shift == 0x7E {
            let found = inFrame && bytes.count >= 18 ? AX25Frame.parse(bytes) : nil
            inFrame = true
            bytes.removeAll(keepingCapacity: true)
            ones = 0; bitCount = 0; byte = 0
            return found
        }
        if shift == 0xFE { inFrame = false; return nil } // Seven ones in a row: aborted.
        guard inFrame else { return nil }
        if !bit, ones == 5 { ones = 0; return nil } // A stuffed zero, not data.
        ones = bit ? ones + 1 : 0
        byte = byte >> 1 | (bit ? 0x80 : 0)
        bitCount += 1
        if bitCount == 8 {
            bytes.append(byte)
            bitCount = 0; byte = 0
            if bytes.count > 512 { inFrame = false }
        }
        return nil
    }
}

/// Finds bit centres from the signal's own transitions.
private struct BitClock {
    let samplesPerBit: Double
    let pull: Double
    private var phase = 0.0
    private var previous = false

    init(samplesPerBit: Double, pull: Double) {
        self.samplesPerBit = samplesPerBit
        self.pull = pull
    }

    /// Returns the level at the middle of a bit, when this sample is one.
    mutating func step(_ level: Bool) -> Bool? {
        if level != previous {
            // A transition belongs at the edge of a bit, so ease towards whichever edge is nearer.
            if phase < samplesPerBit / 2 { phase *= 1 - pull } else { phase += (samplesPerBit - phase) * pull }
            previous = level
        }
        let before = phase
        phase += 1
        var out: Bool?
        if before < samplesPerBit / 2, phase >= samplesPerBit / 2 { out = level }
        if phase >= samplesPerBit { phase -= samplesPerBit }
        return out
    }
}

/// Bell 202 at 1200 baud, the APRS standard. Several slicers run side by side, because a radio's
/// audio response tilts one tone against the other by an amount nobody knows in advance.
final class AFSKDecoder {
    private struct Slicer {
        let bias: Float
        var clock: BitClock
        var hdlc = HDLCReceiver()
        var lastBit = false
    }
    private let window: Int
    private var ring: [(mi: Float, mq: Float, si: Float, sq: Float)]
    private var at = 0
    private var mi: Float = 0, mq: Float = 0, si: Float = 0, sq: Float = 0
    private var markPhase = 0.0, spacePhase = 0.0
    private let markStep: Double, spaceStep: Double
    private var slicers: [Slicer]

    init(sampleRate: Double) {
        let perBit = sampleRate / 1200
        window = max(4, Int(perBit.rounded()))
        ring = Array(repeating: (0, 0, 0, 0), count: window)
        markStep = 2 * .pi * 1200 / sampleRate
        spaceStep = 2 * .pi * 2200 / sampleRate
        slicers = [0, 0.25, -0.25, 0.5, -0.5].map { Slicer(bias: $0, clock: BitClock(samplesPerBit: perBit, pull: 0.2)) }
    }

    func feed(_ samples: [Float], found: (AX25Frame) -> Void) {
        for x in samples {
            let new = (mi: x * Float(cos(markPhase)), mq: x * Float(sin(markPhase)), si: x * Float(cos(spacePhase)), sq: x * Float(sin(spacePhase)))
            markPhase += markStep; if markPhase > 2 * .pi { markPhase -= 2 * .pi }
            spacePhase += spaceStep; if spacePhase > 2 * .pi { spacePhase -= 2 * .pi }
            let old = ring[at]
            ring[at] = new
            at = (at + 1) % window
            mi += new.mi - old.mi; mq += new.mq - old.mq
            si += new.si - old.si; sq += new.sq - old.sq
            let mark = mi * mi + mq * mq, space = si * si + sq * sq
            // Relative, so a fading signal slices at the same place.
            let d = (mark - space) / (mark + space + 1e-9)
            for i in slicers.indices {
                guard let level = slicers[i].clock.step(d > slicers[i].bias) else { continue }
                let bit = level == slicers[i].lastBit // NRZI: no change is a one.
                slicers[i].lastBit = level
                if let frame = slicers[i].hdlc.push(bit) { found(frame) }
            }
        }
    }
}

/// G3RUH at 9600 baud. Reads the raw FM audio, removes the scrambler and NRZI, and doesn't care
/// which way up the signal is.
final class G3RUHDecoder {
    private var clock: BitClock
    private var hdlc = HDLCReceiver()
    private var lfsr: UInt32 = 0
    private var lastLevel = false
    private var average: Float = 0
    private let settle: Float

    init(sampleRate: Double) {
        clock = BitClock(samplesPerBit: sampleRate / 9600, pull: 0.1)
        settle = Float(1 / (sampleRate * 0.02))
    }

    func feed(_ samples: [Float], found: (AX25Frame) -> Void) {
        for x in samples {
            // Leaves out any offset from being slightly off frequency.
            average += (x - average) * settle
            guard let high = clock.step(x - average > 0) else { continue }
            let bit: UInt32 = high ? 1 : 0
            let level = (bit ^ (lfsr >> 16) ^ (lfsr >> 11)) & 1 == 1
            lfsr = lfsr << 1 | bit
            let data = level == lastLevel
            lastLevel = level
            if let frame = hdlc.push(data) { found(frame) }
        }
    }
}

/// Runs both speeds over the same audio, and reports each frame once.
final class PacketDecoder {
    private let afsk: AFSKDecoder
    private let g3ruh: G3RUHDecoder?
    private var recent: [(frame: AX25Frame, at: Int)] = []
    private var clock = 0
    private let rate: Double

    init(sampleRate: Double) {
        rate = sampleRate
        afsk = AFSKDecoder(sampleRate: sampleRate)
        // Below this there aren't enough samples per bit to find 9600 baud.
        g3ruh = sampleRate >= 38_400 ? G3RUHDecoder(sampleRate: sampleRate) : nil
    }

    func feed(_ samples: [Float]) -> [AX25Frame] {
        var out: [AX25Frame] = []
        let handle: (AX25Frame) -> Void = { [self] frame in
            // Several slicers usually catch the same frame.
            recent.removeAll { Double(clock - $0.at) > rate }
            if !recent.contains(where: { $0.frame == frame }) { out.append(frame) }
            recent.append((frame, clock))
        }
        afsk.feed(samples, found: handle)
        g3ruh?.feed(samples, found: handle)
        clock += samples.count
        return out
    }
}

/// What an APRS packet says.
struct APRSReport: Equatable {
    enum Kind: String { case position = "Position", status = "Status", message = "Message", telemetry = "Telemetry", object = "Object", other = "Packet" }
    var kind: Kind
    var latitude: Double?
    var longitude: Double?
    var addressee: String?
    var text: String

    private static func string(_ b: ArraySlice<UInt8>) -> String {
        String(decoding: b.map { (0x20...0x7E).contains($0) ? $0 : 0x2E }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// "4903.50N", where trailing digits may be spaces if the sender chose to be vague. Uses the middle of that area.
    static func angle(_ b: ArraySlice<UInt8>, degreeDigits: Int) -> Double? {
        let a = Array(b)
        guard a.count == degreeDigits + 6, a[degreeDigits + 2] == 0x2E else { return nil }
        var digits: [Int] = [], blanks = 0
        for (i, c) in a.dropLast().enumerated() where i != degreeDigits + 2 {
            if c == 0x20 { digits.append(5); blanks += 1 }
            else if (0x30...0x39).contains(c) { digits.append(Int(c) - 0x30) }
            else { return nil }
        }
        guard blanks < 5 else { return nil }
        let degrees = digits[0..<degreeDigits].reduce(0) { $0 * 10 + $1 }
        let m = digits[degreeDigits...]
        let minutes = m.reduce(0.0) { $0 * 10 + Double($1) } / 100
        guard minutes < 60 else { return nil }
        let value = Double(degrees) + minutes / 60
        switch a[degreeDigits + 5] {
        case 0x4E, 0x45: return value // N, E
        case 0x53, 0x57: return -value // S, W
        default: return nil
        }
    }

    private static func position(_ b: ArraySlice<UInt8>) -> (lat: Double, lon: Double, rest: ArraySlice<UInt8>)? {
        let a = b.startIndex
        guard b.count >= 13 else { return nil }
        if (0x30...0x39).contains(b[a]) {
            guard b.count >= 19, let lat = angle(b[a..<(a + 8)], degreeDigits: 2), let lon = angle(b[(a + 9)..<(a + 18)], degreeDigits: 3) else { return nil }
            return (lat, lon, b[(a + 19)...])
        }
        // Compressed: symbol table, four base-91 digits each way, symbol, then course and type.
        func base91(_ s: ArraySlice<UInt8>) -> Double? {
            var v = 0.0
            for c in s {
                guard c >= 33, c <= 124 else { return nil }
                v = v * 91 + Double(c - 33)
            }
            return v
        }
        guard let y = base91(b[(a + 1)..<(a + 5)]), let x = base91(b[(a + 5)..<(a + 9)]) else { return nil }
        return (90 - y / 380926, -180 + x / 190463, b[(a + 13)...])
    }

    /// Mic-E puts the latitude in the destination callsign, to save bytes. Common on trackers and the ISS.
    private static func micE(destination: String, info: [UInt8]) -> (lat: Double, lon: Double, comment: ArraySlice<UInt8>)? {
        let dest = Array(destination.split(separator: "-").first ?? "").compactMap(\.asciiValue)
        guard dest.count == 6, info.count >= 9 else { return nil }
        var digits: [Int] = []
        for c in dest {
            switch c {
            case 0x30...0x39: digits.append(Int(c) - 0x30)
            case 0x41...0x4A: digits.append(Int(c) - 0x41)
            case 0x50...0x59: digits.append(Int(c) - 0x50)
            case 0x4B, 0x4C, 0x5A: digits.append(5)
            default: return nil
            }
        }
        let north = dest[3] >= 0x50, plus100 = dest[4] >= 0x50, west = dest[5] >= 0x50
        var lat = Double(digits[0] * 10 + digits[1]) + (Double(digits[2] * 10 + digits[3]) + Double(digits[4] * 10 + digits[5]) / 100) / 60
        if !north { lat = -lat }
        guard info[1] >= 28, info[2] >= 28, info[3] >= 28 else { return nil }
        var d = Int(info[1]) - 28
        if plus100 { d += 100 }
        if d >= 190 { d -= 190 } else if d >= 180 { d -= 80 }
        var m = Int(info[2]) - 28
        if m >= 60 { m -= 60 }
        let h = Int(info[3]) - 28
        var lon = Double(d) + (Double(m) + Double(h) / 100) / 60
        if west { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon, info[9...])
    }

    /// Nil if it isn't APRS, as plain packet traffic isn't.
    static func parse(_ frame: AX25Frame) -> APRSReport? {
        let b = frame.info
        guard let type = b.first else { return nil }
        let all = b[...]
        switch type {
        case 0x21, 0x3D, 0x2F, 0x40: // ! = / @
            let start = (type == 0x2F || type == 0x40) ? 8 : 1
            guard b.count > start, let p = position(all[start...]) else { return nil }
            return APRSReport(kind: .position, latitude: p.lat, longitude: p.lon, text: string(p.rest))
        case 0x60, 0x27: // ` '
            guard let p = micE(destination: frame.destination, info: b) else { return nil }
            return APRSReport(kind: .position, latitude: p.lat, longitude: p.lon, text: string(p.comment))
        case 0x3E: // >
            return APRSReport(kind: .status, text: string(all[1...]))
        case 0x3A: // :
            guard b.count >= 11, b[10] == 0x3A else { return nil }
            return APRSReport(kind: .message, addressee: string(all[1..<10]), text: string(all[11...]))
        case 0x3B: // ;
            guard b.count >= 37, let p = position(all[18...]) else { return nil }
            return APRSReport(kind: .object, latitude: p.lat, longitude: p.lon, addressee: string(all[1..<10]), text: string(p.rest))
        case 0x54: // T#
            guard b.count > 1, b[1] == 0x23 else { return nil }
            return APRSReport(kind: .telemetry, text: string(all[2...]))
        default:
            return nil
        }
    }
}

/// Reads a growing WAV file from the start, a chunk at a time.
final class WavTail {
    private let folder: URL
    private var file: FileHandle?
    private(set) var format: WavFormat?
    private var offset: UInt64 = 0

    init(folder: URL) { self.folder = folder }

    /// What's new since last time, or nil if there's nothing yet.
    func read() -> [Float]? {
        if file == nil, !open() { return nil }
        guard let file, let format, let end = try? file.seekToEnd() else { return nil }
        let frame = UInt64(format.frameBytes)
        let available = (end - min(end, offset)) / frame * frame
        guard available > 0, (try? file.seek(toOffset: offset)) != nil,
              let data = try? file.read(upToCount: Int(available)), !data.isEmpty else { return nil }
        offset += UInt64(data.count) / frame * frame
        return WavFormat.samples(data, channels: format.channels)
    }

    private func open() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let wav = names.first(where: { $0.pathExtension.lowercased() == "wav" }),
              let handle = try? FileHandle(forReadingFrom: wav),
              let head = try? handle.read(upToCount: 256), let parsed = WavFormat.parse(head) else { return false }
        file = handle
        format = parsed
        offset = parsed.dataOffset
        return true
    }

    deinit { try? file?.close() }
}
