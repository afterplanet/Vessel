import CoreGraphics
import Foundation

/// A slow-scan TV format: how long each part of a scan lasts, and in what order.
struct SSTVMode: Equatable {
    enum Channel: Equatable { case red, green, blue, y, y2, cr, cb, robot36Chroma }
    struct Scan: Equatable {
        let channel: Channel
        let startMs: Double
        let lengthMs: Double
    }

    let name: String
    let vis: Int
    let width: Int
    let height: Int
    let frameMs: Double
    let syncMs: Double
    /// Where the sync pulse falls within a frame. Scottie is the odd one, with it just before red.
    let syncOffsetMs: Double
    /// Between the end of the header and the first frame.
    let leadInMs: Double
    let scans: [Scan]

    /// PD and Robot 36 carry more than one row per frame, in different ways.
    var rowsPerFrame: Int { scans.contains { $0.channel == .y2 } ? 2 : 1 }
    var frames: Int { height / rowsPerFrame }

    private static func rgb(_ name: String, vis: Int, width: Int = 320, height: Int = 256, scan: Double) -> SSTVMode {
        // Martin: sync 4.862, porch and separators 0.572, in green, blue, red order.
        let s = 4.862, gap = 0.572
        let g = s + gap, b = g + scan + gap, r = b + scan + gap
        return SSTVMode(name: name, vis: vis, width: width, height: height, frameMs: r + scan + gap, syncMs: s, syncOffsetMs: 0, leadInMs: 0,
                        scans: [Scan(channel: .green, startMs: g, lengthMs: scan), Scan(channel: .blue, startMs: b, lengthMs: scan),
                                Scan(channel: .red, startMs: r, lengthMs: scan)])
    }

    private static func scottie(_ name: String, vis: Int, scan: Double) -> SSTVMode {
        // A frame runs separator, green, separator, blue, sync, porch, red. One extra sync comes first.
        let gap = 1.5, sync = 9.0
        let g = gap, b = g + scan + gap, syncAt = b + scan, r = syncAt + sync + gap
        return SSTVMode(name: name, vis: vis, width: 320, height: 256, frameMs: r + scan, syncMs: sync, syncOffsetMs: syncAt, leadInMs: sync,
                        scans: [Scan(channel: .green, startMs: g, lengthMs: scan), Scan(channel: .blue, startMs: b, lengthMs: scan),
                                Scan(channel: .red, startMs: r, lengthMs: scan)])
    }

    private static func pd(_ name: String, vis: Int, width: Int, height: Int, scan: Double) -> SSTVMode {
        let start = 20 + 2.08
        return SSTVMode(name: name, vis: vis, width: width, height: height, frameMs: start + scan * 4, syncMs: 20, syncOffsetMs: 0, leadInMs: 0,
                        scans: [Scan(channel: .y, startMs: start, lengthMs: scan), Scan(channel: .cr, startMs: start + scan, lengthMs: scan),
                                Scan(channel: .cb, startMs: start + scan * 2, lengthMs: scan), Scan(channel: .y2, startMs: start + scan * 3, lengthMs: scan)])
    }

    static let all: [SSTVMode] = [
        // Robot 36 alternates red and blue difference on each row, so a frame is one row and its chroma half.
        SSTVMode(name: "Robot 36", vis: 8, width: 320, height: 240, frameMs: 150, syncMs: 9, syncOffsetMs: 0, leadInMs: 0,
                 scans: [Scan(channel: .y, startMs: 12, lengthMs: 88), Scan(channel: .robot36Chroma, startMs: 106, lengthMs: 44)]),
        SSTVMode(name: "Robot 72", vis: 12, width: 320, height: 240, frameMs: 300, syncMs: 9, syncOffsetMs: 0, leadInMs: 0,
                 scans: [Scan(channel: .y, startMs: 12, lengthMs: 138), Scan(channel: .cr, startMs: 156, lengthMs: 69),
                         Scan(channel: .cb, startMs: 231, lengthMs: 69)]),
        rgb("Martin M1", vis: 44, scan: 146.432),
        rgb("Martin M2", vis: 40, scan: 73.216),
        scottie("Scottie S1", vis: 60, scan: 138.24),
        scottie("Scottie S2", vis: 56, scan: 88.064),
        scottie("Scottie DX", vis: 76, scan: 345.6),
        pd("PD50", vis: 93, width: 320, height: 256, scan: 91.52),
        pd("PD90", vis: 99, width: 320, height: 256, scan: 170.24),
        pd("PD120", vis: 95, width: 640, height: 496, scan: 121.6),
        pd("PD160", vis: 98, width: 512, height: 400, scan: 195.584),
        pd("PD180", vis: 96, width: 640, height: 496, scan: 183.04),
        pd("PD240", vis: 97, width: 640, height: 496, scan: 244.48),
        pd("PD290", vis: 94, width: 800, height: 616, scan: 228.8),
    ]
}

/// A picture, whole or as far as it's got.
struct SSTVPicture {
    let mode: SSTVMode
    let started: Date
    /// Picked up mid-picture from its sync pulses, so the top is missing.
    let joinedPartway: Bool
    var rgba: [UInt8]
    var rows = 0

    init(mode: SSTVMode, started: Date, joinedPartway: Bool) {
        self.mode = mode
        self.started = started
        self.joinedPartway = joinedPartway
        rgba = [UInt8](repeating: 0, count: mode.width * mode.height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
    }

    var isComplete: Bool { rows >= mode.height }

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * mode.width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2])
    }

    var image: CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: mode.width, height: mode.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mode.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Turns audio into pictures, as it arrives. Audio tones become a frequency track, the header
/// (or failing that the rhythm of the sync pulses) names the format, and then each frame is read
/// off the track at the times the format says, nudged along by its sync pulse.
final class SSTVDecoder {
    private(set) var current: SSTVPicture?
    /// Called with each picture that ends, complete or not. Scraps too short to show anything aren't reported.
    var onFinished: ((SSTVPicture) -> Void)?
    static let shortestWorthKeeping = 16

    // Tone demodulator: mixed down to the middle of the SSTV band, filtered, reduced to about 12 kHz.
    private static let centre = 1900.0
    private let factor: Int
    let rate: Double
    private let taps: [Float]
    private var inI: [Float], inQ: [Float]
    private var inPos = 0, phase = 0.0, sinceOutput = 0
    private let phaseStep: Double
    private var last: (i: Float, q: Float) = (0, 0)

    // The frequency track, addressed by sample number from the start of the stream.
    private var track: [Float] = []
    private var trackBase = 0
    private var trackEnd: Int { trackBase + track.count }

    // Averages over 10 ms, which is what the header is matched against.
    private let binLength: Int
    private var bins: [Float] = []
    private var binSum: Float = 0
    private var binCount = 0

    // Recent sync-like pulses, for joining a picture that's already under way.
    private var pulses: [(start: Int, length: Int)] = []
    private var pulseRun = 0

    private struct Reading {
        var frame = 0
        var start: Double
        var frameSamples: Double
        var offset: Float
        var locked = false
        var missed = 0
        var chromaHold: [Float] = []
        var chromaHoldIsRed = false
    }
    private var reading: Reading?

    init(sampleRate: Double) {
        factor = max(1, Int((sampleRate / 12000).rounded()))
        rate = sampleRate / Double(factor)
        phaseStep = 2 * .pi * Self.centre / sampleRate
        binLength = max(1, Int(rate * 0.01))
        // Wide enough for 1100 to 2300 Hz around the centre, and a Hamming window to keep it clean.
        let count = max(9, factor * 16 + 1)
        let cutoff = 1100.0 / sampleRate
        var t = (0..<count).map { i -> Float in
            let n = Double(i) - Double(count - 1) / 2
            let sinc = n == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * n) / (.pi * n)
            return Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(count - 1))))
        }
        let sum = t.reduce(0, +)
        t = t.map { $0 / sum }
        taps = t
        inI = [Float](repeating: 0, count: count)
        inQ = [Float](repeating: 0, count: count)
    }

    func feed(_ samples: [Float]) {
        for s in samples {
            inI[inPos] = s * Float(cos(phase))
            inQ[inPos] = -s * Float(sin(phase))
            inPos = (inPos + 1) % taps.count
            phase += phaseStep
            if phase > 2 * .pi { phase -= 2 * .pi }
            sinceOutput += 1
            guard sinceOutput >= factor else { continue }
            sinceOutput = 0
            var i: Float = 0, q: Float = 0
            var p = inPos
            for t in taps {
                i += t * inI[p]
                q += t * inQ[p]
                p = (p + 1) % taps.count
            }
            let angle = atan2(q * last.i - i * last.q, i * last.i + q * last.q)
            last = (i, q)
            push(Float(Self.centre) + angle * Float(rate) / (2 * .pi))
        }
        readFrames()
        trim()
    }

    /// The signal ended. Whatever has been drawn so far is the picture.
    func finish() {
        guard let picture = current else { return }
        current = nil
        reading = nil
        if picture.rows >= Self.shortestWorthKeeping { onFinished?(picture) }
    }

    private func push(_ f: Float) {
        track.append(f)
        trackPulse(f)
        binSum += f
        binCount += 1
        if binCount == binLength {
            bins.append(binSum / Float(binCount))
            binSum = 0
            binCount = 0
            if bins.count > 140 { bins.removeFirst(bins.count - 120) }
            matchHeader()
        }
    }

    private func trim() {
        var keep = trackEnd - Int(rate * 3)
        if let r = reading { keep = min(keep, Int(r.start) - Int(rate * 0.1)) }
        if keep > trackBase + Int(rate) {
            track.removeFirst(keep - trackBase)
            trackBase = keep
        }
    }

    // MARK: Finding a picture

    /// 300 ms of leader at 1900 Hz, a 30 ms start bit at 1200, eight 30 ms bits with 1100 for a one and
    /// 1300 for a zero, lowest first with even parity, and a 30 ms stop bit at 1200. Anything off-tune
    /// by Doppler is off by the same amount throughout, so the leader sets the reference.
    private func matchHeader() {
        let n = bins.count
        // Stop, eight bits and start make 30 bins, with the leader before them.
        guard n >= 50 else { return }
        func mid(_ slot: Int) -> Float { bins[n - 2 - slot * 3] } // slot 0 is the stop bit, counting back
        let leader = bins[(n - 30 - 18)..<(n - 30 - 3)]
        let mean = leader.reduce(0, +) / Float(leader.count)
        guard abs(mean - 1900) < 400, leader.allSatisfy({ abs($0 - mean) < 45 }) else { return }
        let offset = mean - 1900
        func near(_ f: Float, _ target: Float) -> Bool { abs(f - offset - target) < 45 }
        guard near(mid(0), 1200), near(mid(9), 1200) else { return }
        var code = 0, ones = 0
        for bit in 0..<8 {
            let f = mid(8 - bit)
            if near(f, 1100) {
                ones += 1
                if bit < 7 { code |= 1 << bit }
            } else if !near(f, 1300) {
                return
            }
        }
        guard ones % 2 == 0, let mode = SSTVMode.all.first(where: { $0.vis == code }) else { return }
        // Decoded a header while reading: the old picture is over, so start the new one.
        finish()
        begin(mode, at: Double(trackEnd) + mode.leadInMs * rate / 1000, offset: offset, partway: false)
        bins.removeAll()
        pulses.removeAll()
    }

    private func trackPulse(_ f: Float) {
        if f < 1350 {
            pulseRun += 1
            return
        }
        defer { pulseRun = 0 }
        guard reading == nil else { return }
        let ms = Double(pulseRun) * 1000 / rate
        guard ms >= 3, ms <= 26 else { return }
        pulses.append((trackEnd - 1 - pulseRun, pulseRun))
        if pulses.count > 7 { pulses.removeFirst(pulses.count - 7) }
        joinFromRhythm()
    }

    /// Several sync pulses, evenly spaced at a format's frame time and the right length. Joining a picture
    /// that's already under way needs this, since its header has gone by.
    private func joinFromRhythm() {
        guard pulses.count == 7 else { return }
        for mode in SSTVMode.all {
            let frame = mode.frameMs * rate / 1000
            let spaced = zip(pulses, pulses.dropFirst()).allSatisfy { abs(Double($1.start - $0.start) - frame) < max(4, frame * 0.004) }
            let lengths = pulses.allSatisfy { abs(Double($0.length) * 1000 / rate - mode.syncMs) < max(1.5, mode.syncMs * 0.25) }
            if spaced && lengths {
                let first = pulses[pulses.count - 1].start
                begin(mode, at: Double(first) - mode.syncOffsetMs * rate / 1000 + frame, offset: 0, partway: true)
                pulses.removeAll()
                return
            }
        }
    }

    private func begin(_ mode: SSTVMode, at start: Double, offset: Float, partway: Bool) {
        current = SSTVPicture(mode: mode, started: Date(), joinedPartway: partway)
        reading = Reading(start: start, frameSamples: mode.frameMs * rate / 1000, offset: offset)
    }

    // MARK: Reading a picture

    private func readFrames() {
        while let r = reading, let mode = current?.mode {
            // A little beyond the frame, so the search for the sync pulse has room.
            guard Double(trackEnd) >= r.start + r.frameSamples + rate * 0.03 else { return }
            readFrame(mode)
        }
    }

    /// How much of `length` samples from `at` looks like a sync pulse.
    private func syncScore(at: Int, length: Int, offset: Float) -> Double {
        let from = at - trackBase
        guard from >= 0, from + length <= track.count else { return 0 }
        var hits = 0
        for i in from..<(from + length) where abs(track[i] - offset - 1200) < 130 { hits += 1 }
        return Double(hits) / Double(length)
    }

    private func readFrame(_ mode: SSTVMode) {
        guard var r = reading else { return }
        // Find this frame's sync pulse: widely for the first, since the header only gives a rough start.
        let toSamples = rate / 1000
        let expected = r.start + mode.syncOffsetMs * toSamples
        let reach = r.locked ? 3 * toSamples : 22 * toSamples
        let length = max(1, Int(mode.syncMs * toSamples))
        var best = Int(expected), bestScore = -1.0, bestDistance = Double.infinity
        for c in Int(expected - reach)...Int(expected + reach) {
            let score = syncScore(at: c, length: length, offset: r.offset)
            let distance = abs(Double(c) - expected)
            if score > bestScore + 0.001 || (abs(score - bestScore) <= 0.001 && distance < bestDistance) {
                best = c; bestScore = score; bestDistance = distance
            }
        }
        if bestScore >= 0.6 {
            let error = Double(best) - expected
            if r.locked {
                // Sound cards never run at quite the stated rate, and this keeps the picture from leaning.
                r.start += error * 0.3
                r.frameSamples += error * 0.02
            } else {
                r.start += error
                r.locked = true
            }
            r.missed = 0
        } else {
            r.missed += 1
        }

        // Too long without a sync pulse means the signal has gone. Rows drawn from nothing but noise go too.
        if r.missed >= 12 {
            if var picture = current {
                picture.rows = max(0, picture.rows - r.missed * mode.rowsPerFrame)
                current = picture
            }
            finish()
            return
        }

        draw(mode, reading: &r)
        r.frame += 1
        r.start += r.frameSamples
        reading = r
        if r.frame >= mode.frames, mode.scans.contains(where: { $0.channel != .robot36Chroma }) {
            if let picture = current, picture.rows >= mode.height { finish() }
        }
    }

    private func samples(_ scan: SSTVMode.Scan, width: Int, reading r: Reading) -> [Float] {
        let toSamples = rate / 1000
        let start = r.start + scan.startMs * toSamples
        let each = scan.lengthMs * toSamples / Double(width)
        var out = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let a = Int(start + Double(x) * each) - trackBase
            let b = max(a + 1, Int(start + Double(x + 1) * each) - trackBase)
            guard a >= 0, b <= track.count else { continue }
            var sum: Float = 0
            for i in a..<b { sum += track[i] }
            out[x] = min(255, max(0, (sum / Float(b - a) - r.offset - 1500) * 255 / 800))
        }
        return out
    }

    private func draw(_ mode: SSTVMode, reading r: inout Reading) {
        guard var picture = current else { return }
        var red: [Float]?, green: [Float]?, blue: [Float]?, y: [Float]?, y2: [Float]?, cr: [Float]?, cb: [Float]?
        var chroma: [Float]?
        for scan in mode.scans {
            let line = samples(scan, width: mode.width, reading: r)
            switch scan.channel {
            case .red: red = line
            case .green: green = line
            case .blue: blue = line
            case .y: y = line
            case .y2: y2 = line
            case .cr: cr = line
            case .cb: cb = line
            case .robot36Chroma: chroma = line
            }
        }
        func put(_ row: Int, _ pixel: (Int) -> (Float, Float, Float)) {
            guard row >= 0, row < mode.height else { return }
            for x in 0..<mode.width {
                let (a, b, c) = pixel(x)
                let i = (row * mode.width + x) * 4
                picture.rgba[i] = UInt8(min(255, max(0, a)))
                picture.rgba[i + 1] = UInt8(min(255, max(0, b)))
                picture.rgba[i + 2] = UInt8(min(255, max(0, c)))
            }
        }
        func colour(_ luma: Float, _ crv: Float, _ cbv: Float) -> (Float, Float, Float) {
            (luma + 1.402 * (crv - 128), luma - 0.714 * (crv - 128) - 0.344 * (cbv - 128), luma + 1.772 * (cbv - 128))
        }

        if let chroma, let y {
            // Robot 36: the separator says which colour difference this row carries: 1500 Hz for red, 2300 for blue.
            let toSamples = rate / 1000
            let from = Int(r.start + 101 * toSamples) - trackBase, to = Int(r.start + 105 * toSamples) - trackBase
            var isRed = r.frame % 2 == 0
            if from >= 0, to <= track.count, to > from {
                let mean = track[from..<to].reduce(0, +) / Float(to - from) - r.offset
                isRed = mean < 1900
            }
            let held = r.chromaHold, heldRed = r.chromaHoldIsRed
            let row = r.frame
            if !held.isEmpty, heldRed != isRed {
                let crLine = isRed ? chroma : held, cbLine = isRed ? held : chroma
                put(row) { colour(y[$0], crLine[$0], cbLine[$0]) }
                picture.rows = max(picture.rows, row + 1)
                // The row before had only half its colour until now.
                if row > 0, let previous = previousLuma { put(row - 1) { colour(previous[$0], crLine[$0], cbLine[$0]) } }
            } else {
                put(row) { (y[$0], y[$0], y[$0]) }
                picture.rows = max(picture.rows, row + 1)
            }
            previousLuma = y
            r.chromaHold = chroma
            r.chromaHoldIsRed = isRed
        } else if let red, let green, let blue {
            put(r.frame) { (red[$0], green[$0], blue[$0]) }
            picture.rows = max(picture.rows, r.frame + 1)
        } else if let y, let cr, let cb {
            let row = r.frame * mode.rowsPerFrame
            put(row) { colour(y[$0], cr[$0], cb[$0]) }
            if let y2 { put(row + 1) { colour(y2[$0], cr[$0], cb[$0]) } }
            picture.rows = max(picture.rows, row + mode.rowsPerFrame)
        }
        current = picture
    }
    private var previousLuma: [Float]?
}
