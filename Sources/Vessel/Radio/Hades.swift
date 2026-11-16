import Foundation

/// AMSAT-EA's HADES-SA (SpinnyONE) and its GENESIS frame format. The format comes from AMSAT-EA's
/// own decoder (CC BY 4.0, https://github.com/AMSAT-EA/HADES-SA_SpinnyONE) and gr-satellites'
/// HADES deframer, and was checked against AMSAT-EA's sample frames.
///
/// On air: training bytes, the sync word 0xBF35, a size byte, then `size` bytes starting with
/// a type and address byte. Telemetry ends in a CRC-16 over the scrambled bytes. Pictures (SSDV),
/// voice (Codec2) and test patterns are sent without one.
enum Hades {
    static let norad = 68446
    static let downlinkHz = 436.875e6
    static let baud = 800.0
    /// It also sends at 200 bps, in the same format.
    static let slowBaud = 200.0
    static let address: UInt8 = 3
    static let sync: UInt16 = 0xBF35
    static let ssdvType = 10
    static let voiceType = 11
    static let patternType = 13
    /// Bytes after the size byte, by frame type.
    static let sizes = [2, 31, 17, 41, 35, 27, 135, 45, 31, 123, 251, 37, 64, 249, 38, 73]
    /// Frames without a CRC of their own.
    static let unchecked: Set<Int> = [ssdvType, voiceType, patternType]

    static let typeNames = ["-", "Power", "Temperatures", "Status", "Power ranges", "Temperature ranges", "Unknown", "Payload",
                            "Antenna", "Extended power", "Picture", "Voice", "Ephemeris", "Test pattern", "Time series", "Mailbox"]

    /// Voice payloads are whitened with this before sending.
    static let voiceMask: [UInt8] = [
        0xed, 0x15, 0xd5, 0x3b, 0x34, 0x70, 0xe0, 0xfd, 0xed, 0x83, 0x90, 0xdb,
        0xaa, 0x2e, 0x25, 0xd6, 0x5e, 0x81, 0x41, 0x86, 0xbd, 0x67, 0x79, 0x5d,
        0x70, 0xa1, 0x13, 0xce, 0x50, 0x0c, 0x19, 0xca, 0xfb, 0x44, 0x0d]

    /// CRC-16/CCITT-FALSE.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// GENESIS' self-synchronising scrambler (1 + z^-12 + z^-17). As built, it leaves the lowest
    /// bit of every byte alone and doesn't advance on it.
    static func scramble(_ bytes: [UInt8]) -> [UInt8] { run(bytes, descrambling: false) }
    static func descramble(_ bytes: [UInt8]) -> [UInt8] { run(bytes, descrambling: true) }

    private static func run(_ bytes: [UInt8], descrambling: Bool) -> [UInt8] {
        var state: UInt32 = 1 << 16
        return bytes.map { byte in
            var out: UInt8 = 0
            for k in 0..<7 {
                let bit = UInt32(byte >> (7 - k)) & 1
                let o = (bit ^ (state >> 16) ^ (state >> 11)) & 1
                out = out << 1 | UInt8(o)
                state = ((state << 1) | (descrambling ? bit : o)) & 0x1FFFF
            }
            return out << 1 | (byte & 1)
        }
    }

    struct Frame: Equatable {
        let type: Int
        let address: UInt8
        /// From the type byte on, descrambled and without its CRC.
        let bytes: [UInt8]
        /// Nil for the frame types that carry none.
        let crcOK: Bool?

        var name: String { Hades.typeNames[type] }

        /// A picture frame is a whole SSDV packet, whose callsign field doubles as the sync and size.
        var ssdvPacket: [UInt8]? {
            guard type == Hades.ssdvType, bytes.count == Hades.sizes[Hades.ssdvType] else { return nil }
            return [0x55, 0x66, 0xBF, 0x35, UInt8(Hades.sizes[Hades.ssdvType])] + bytes
        }

        /// A voice frame: its number, and the 35 bytes of Codec2 with the whitening removed.
        var voice: (number: Int, codec2: [UInt8])? {
            guard type == Hades.voiceType, bytes.count == Hades.sizes[Hades.voiceType] else { return nil }
            return (Int(bytes[1]), zip(bytes[2...], Hades.voiceMask).map { $0 ^ $1 })
        }
    }

    /// Checks and unpacks the bytes after the size byte.
    static func parse(_ raw: [UInt8]) -> Frame? {
        guard let first = raw.first else { return nil }
        let type = Int(first >> 4), addr = first & 0x0F
        guard addr == address, type > 0, type < sizes.count, raw.count == sizes[type] else { return nil }
        if unchecked.contains(type) { return Frame(type: type, address: addr, bytes: raw, crcOK: nil) }
        let n = raw.count
        let sent = UInt16(raw[n - 2]) << 8 | UInt16(raw[n - 1])
        guard crc16(raw[0..<(n - 2)]) == sent else { return nil }
        return Frame(type: type, address: addr, bytes: [first] + descramble(Array(raw[1..<(n - 2)])), crcOK: true)
    }

    /// What the satellite sends for a frame, for tests: training, sync, size, then the frame.
    static func onAir(type: Int, payload: [UInt8]) -> [UInt8] {
        let first = UInt8(type << 4) | address
        var body: [UInt8]
        if unchecked.contains(type) {
            body = [first] + payload
        } else {
            body = [first] + scramble(payload)
            let crc = crc16(body)
            body += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        return [UInt8](repeating: 0x55, count: 8) + [0xBF, 0x35, UInt8(body.count)] + body
    }

    /// Finds frames in a stream of bits, most significant bit first.
    struct Deframer {
        private enum State { case hunting, size, data }
        private var state = State.hunting
        private var shift: UInt16 = 0
        private var byte: UInt8 = 0
        private var bitCount = 0
        private var want = 0
        private var buffer: [UInt8] = []

        mutating func push(_ bit: Bool) -> Frame? {
            switch state {
            case .hunting:
                shift = shift << 1 | (bit ? 1 : 0)
                if shift == Hades.sync { state = .size; byte = 0; bitCount = 0 }
                return nil
            case .size, .data:
                byte = byte << 1 | (bit ? 1 : 0)
                bitCount += 1
                guard bitCount == 8 else { return nil }
                let b = byte
                byte = 0; bitCount = 0
                if state == .size {
                    // Only sizes the satellite actually uses.
                    guard Hades.sizes.dropFirst().contains(Int(b)) else { reset(); return nil }
                    want = Int(b); buffer = []; buffer.reserveCapacity(want)
                    state = .data
                    return nil
                }
                buffer.append(b)
                if buffer.count == 1, Hades.parseHeader(b, size: want) == false { reset(); return nil }
                guard buffer.count == want else { return nil }
                let frame = Hades.parse(buffer)
                reset()
                return frame
            }
        }

        private mutating func reset() { state = .hunting; shift = 0 }
    }

    /// Whether a type byte fits the size that came before it.
    fileprivate static func parseHeader(_ first: UInt8, size: Int) -> Bool {
        let type = Int(first >> 4)
        return first & 0x0F == address && type > 0 && type < sizes.count && sizes[type] == size
    }
}

/// Binary FSK from an FM discriminator: the level says which tone, and a clock picks the middle
/// of each bit. Works on the discriminator output, so any frequency offset is just a level shift.
struct FSKBits {
    let samplesPerBit: Double
    private var phase = 0.0
    private var previous = false
    private var average: Double = 0
    private var smooth: [Float]
    private var smoothAt = 0
    private var smoothSum: Float = 0
    private let averaging: Double

    init(sampleRate: Double, baud: Double) {
        samplesPerBit = sampleRate / baud
        // Half a bit of smoothing takes off noise without blurring one bit into the next.
        smooth = [Float](repeating: 0, count: max(1, Int(samplesPerBit / 2)))
        // The middle level follows over about 30 bits, to soak up frequency offset and drift.
        averaging = 1 / (samplesPerBit * 30)
    }

    /// One discriminator sample. Returns a bit when this sample is the middle of one.
    mutating func step(_ x: Float) -> Bool? {
        smoothSum += x - smooth[smoothAt]
        smooth[smoothAt] = x
        smoothAt = (smoothAt + 1) % smooth.count
        let v = Double(smoothSum) / Double(smooth.count)
        average += (v - average) * averaging
        let level = v > average
        if level != previous {
            // A change belongs at the edge of a bit, so ease towards whichever edge is nearer.
            if phase < samplesPerBit / 2 { phase *= 0.7 } else { phase += (samplesPerBit - phase) * 0.3 }
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

/// Raw radio samples in, HADES frames out. Moves the signal to zero, narrows it, and
/// FM-demodulates it. Listens at both speeds, and both polarities, as which tone means 1 isn't certain.
struct HadesReceiver {
    let inputRate: Double
    /// Where the signal sits relative to the centre of the capture. Doppler moves this.
    var offsetHz = 0.0

    private let decimation: Int
    private let rate: Double
    private let taps: [Float]
    private var histRe: [Float], histIm: [Float]
    private var histPos = 0
    private var phase = 0.0
    private var boxRe: Float = 0, boxIm: Float = 0, boxCount = 0, firstStage: Int
    private var skip = 0
    private var lastRe: Float = 1, lastIm: Float = 0
    private var slicers: [(bits: FSKBits, normal: Hades.Deframer, inverted: Hades.Deframer)] = []

    init(inputRate: Double) {
        self.inputRate = inputRate
        // Two stages down to about 16 kHz, enough for 800 baud at up to a few kHz of deviation.
        firstStage = max(1, Int((inputRate / 64_000).rounded(.down)))
        let mid = inputRate / Double(firstStage)
        decimation = max(1, Int((mid / 16_000).rounded()))
        rate = mid / Double(decimation)
        let n = 63, fc = 4_000 / mid
        var h = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i - n / 2)
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * w)
        }
        taps = h
        histRe = [Float](repeating: 0, count: n)
        histIm = [Float](repeating: 0, count: n)
        slicers = Self.slicers(rate: rate)
    }

    private static func slicers(rate: Double) -> [(bits: FSKBits, normal: Hades.Deframer, inverted: Hades.Deframer)] {
        [Hades.baud, Hades.slowBaud].map { (FSKBits(sampleRate: rate, baud: $0), Hades.Deframer(), Hades.Deframer()) }
    }

    /// `iq` is interleaved I and Q.
    mutating func process(_ iq: [Float]) -> [Hades.Frame] {
        var found: [Hades.Frame] = []
        let step = -2 * Double.pi * offsetHz / inputRate
        let n = taps.count
        var i = 0
        while i + 1 < iq.count {
            let c = Float(cos(phase)), s = Float(sin(phase))
            boxRe += iq[i] * c - iq[i + 1] * s
            boxIm += iq[i] * s + iq[i + 1] * c
            i += 2
            phase += step
            if phase > .pi { phase -= 2 * .pi } else if phase < -.pi { phase += 2 * .pi }
            boxCount += 1
            guard boxCount == firstStage else { continue }
            histRe[histPos] = boxRe; histIm[histPos] = boxIm
            histPos = (histPos + 1) % n
            boxRe = 0; boxIm = 0; boxCount = 0
            skip += 1
            guard skip == decimation else { continue }
            skip = 0
            var re: Float = 0, im: Float = 0
            var k = histPos
            for t in 0..<n {
                re += histRe[k] * taps[t]; im += histIm[k] * taps[t]
                k += 1
                if k == n { k = 0 }
            }
            // FM: the change in phase since the last sample.
            let d = atan2(im * lastRe - re * lastIm, re * lastRe + im * lastIm)
            lastRe = re; lastIm = im
            found += demodulated(d)
        }
        return found
    }

    /// Already FM-demodulated audio, at `rate`.
    mutating func processAudio(_ samples: [Float]) -> [Hades.Frame] {
        samples.flatMap { demodulated($0) }
    }

    private mutating func demodulated(_ x: Float) -> [Hades.Frame] {
        var out: [Hades.Frame] = []
        for i in slicers.indices {
            guard let bit = slicers[i].bits.step(x) else { continue }
            if let f = slicers[i].normal.push(bit) { out.append(f) }
            if let f = slicers[i].inverted.push(!bit) { out.append(f) }
        }
        return out
    }

    /// For audio input: a receiver whose demodulated rate is the audio rate.
    static func audio(rate: Double) -> HadesReceiver {
        var r = HadesReceiver(inputRate: rate)
        r.slicers = slicers(rate: rate)
        return r
    }
}
