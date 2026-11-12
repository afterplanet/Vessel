import Foundation
import SwiftUI
import simd

/// Turns raw radio samples into the audio of one sideband, the way an SSB receiver does. The
/// decoder engine has no SSB mode, and FT8, FT4 and voice on linear transponders all need it.
struct SSBDemod {
    let inputRate: Double
    let outputRate: Double
    let usb: Bool
    /// Where the signal's carrier sits relative to the centre of the capture. Doppler moves this.
    var offsetHz = 0.0

    private let first: Int
    private let second = 4
    private let taps: [Float]
    private var phase = 0.0
    private var boxRe: Float = 0, boxIm: Float = 0, boxCount = 0
    private var histRe: [Float], histIm: [Float]
    private var histPos = 0, skip = 0
    private var outPhase = 0.0

    init(inputRate: Double, usb: Bool) {
        self.inputRate = inputRate
        self.usb = usb
        first = max(1, Int((inputRate / 12_000 / 4).rounded()))
        outputRate = inputRate / Double(first * 4)
        // Low-pass at 1.45 kHz: the sideband is centred on zero, so this keeps 0 to 2.9 kHz of audio.
        let mid = inputRate / Double(first), n = 95
        var h = [Float](repeating: 0, count: n)
        let fc = 1450 / mid
        for i in 0..<n {
            let x = Double(i - n / 2)
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * window)
        }
        taps = h
        histRe = [Float](repeating: 0, count: n)
        histIm = [Float](repeating: 0, count: n)
    }

    /// `iq` is interleaved I and Q. Returns audio at `outputRate`.
    mutating func process(_ iq: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(iq.count / 2 / (first * second) + 1)
        // Move the middle of the wanted sideband to zero.
        let shift = offsetHz + (usb ? 1500 : -1500)
        let step = -2 * Double.pi * shift / inputRate
        let back = 2 * Double.pi * (usb ? 1500 : -1500) / outputRate
        let n = taps.count
        var i = 0
        while i + 1 < iq.count {
            let c = Float(cos(phase)), s = Float(sin(phase))
            boxRe += iq[i] * c - iq[i + 1] * s
            boxIm += iq[i] * s + iq[i + 1] * c
            phase += step
            if phase > .pi { phase -= 2 * .pi } else if phase < -.pi { phase += 2 * .pi }
            boxCount += 1
            i += 2
            guard boxCount == first else { continue }
            histRe[histPos] = boxRe / Float(first)
            histIm[histPos] = boxIm / Float(first)
            histPos = (histPos + 1) % n
            boxRe = 0; boxIm = 0; boxCount = 0
            skip += 1
            guard skip == second else { continue }
            skip = 0
            var re: Float = 0, im: Float = 0
            var k = histPos
            for t in 0..<n {
                re += histRe[k] * taps[t]
                im += histIm[k] * taps[t]
                k += 1
                if k == n { k = 0 }
            }
            // Back up to audio frequencies, keeping the real part.
            out.append(re * Float(cos(outPhase)) - im * Float(sin(outPhase)))
            outPhase += back
            if outPhase > .pi { outPhase -= 2 * .pi } else if outPhase < -.pi { outPhase += 2 * .pi }
        }
        return out
    }
}

/// Follows the raw signal file as it's written.
final class IQTail {
    private let folder: URL
    private var file: FileHandle?
    private var bytesPerSample = 2
    private var offset: UInt64 = 0

    init(folder: URL) { self.folder = folder }

    /// New samples as interleaved floats, or nil if there are none or the format isn't one this reads.
    func read(maxBytes: Int = 8_000_000) -> [Float]? {
        if file == nil {
            for (ext, size) in [("cs16", 2), ("cs8", 1)] {
                let url = folder.appendingPathComponent("baseband.\(ext)")
                if let h = try? FileHandle(forReadingFrom: url) {
                    file = h; bytesPerSample = size
                    // Start from what's arriving now, not from the beginning of a long file.
                    offset = (try? h.seekToEnd()) ?? 0
                    break
                }
            }
        }
        guard let file, let end = try? file.seekToEnd() else { return nil }
        let frame = UInt64(bytesPerSample * 2)
        var available = (end - min(end, offset)) / frame * frame
        guard available > 0 else { return nil }
        // Fallen far behind: skip ahead rather than decode stale audio.
        if available > UInt64(maxBytes) { offset = end - UInt64(maxBytes) / frame * frame; available = UInt64(maxBytes) / frame * frame }
        guard (try? file.seek(toOffset: offset)) != nil, let data = try? file.read(upToCount: Int(available)), !data.isEmpty else { return nil }
        offset += UInt64(data.count)
        return data.withUnsafeBytes { raw -> [Float] in
            if bytesPerSample == 2 {
                return raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
            }
            return raw.bindMemory(to: Int8.self).map { Float($0) / 128 }
        }
    }
}

/// Decodes FT8 and FT4 from the signal being saved, one time slot after another.
@MainActor
final class FTMonitor: ObservableObject {
    @Published private(set) var messages: [FTMessage] = []
    @Published private(set) var isFollowing = false
    @Published private(set) var slotsChecked = 0
    static let shownAtMost = 200

    private let worker = Worker()
    private var folder: URL?
    private var satellite: Satellite?
    private var station: Station?
    private var centreHz = 0.0
    private var timer: Timer?

    func follow(_ next: URL?, centreHz: Double = 0, sampleRate: Double = 0, usb: Bool = true, satellite: Satellite? = nil, station: Station? = nil) {
        guard next != folder else { return }
        folder = next
        isFollowing = next != nil
        self.satellite = satellite?.clone()
        self.station = station
        self.centreHz = centreHz
        timer?.invalidate(); timer = nil
        if next != nil {
            messages = []; slotsChecked = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDoppler() }
            }
            updateDoppler()
        }
        worker.follow(next, sampleRate: sampleRate, usb: usb) { [weak self] found, checked in
            Task { @MainActor in
                guard let self else { return }
                self.slotsChecked += checked
                self.messages.insert(contentsOf: found, at: 0)
                if self.messages.count > Self.shownAtMost { self.messages.removeLast(self.messages.count - Self.shownAtMost) }
            }
        }
    }

    /// The signal's tones drift with the satellite's motion, far more than the decoder tolerates.
    private func updateDoppler() {
        guard let sat = satellite, let st = station else { worker.setOffset(0); return }
        let jd = Astro.julianDate(), jd2 = jd + 1.0 / 86400
        guard let r1 = sat.position(jd: jd), let r2 = sat.position(jd: jd2) else { return }
        let g = GroundPoint(lat: st.lat, lon: st.lon)
        let rate = simd_length(Astro.ecef(r2, gmst: Astro.gmst(jd2)) - g.position) - simd_length(Astro.ecef(r1, gmst: Astro.gmst(jd)) - g.position)
        worker.setOffset(Doppler.downlink(centreHz, rangeRate: rate) - centreHz)
    }

    /// Which samples make up the slot that just ended, taking the newest sample as now. `delay`
    /// allows for the file running behind the air. Nil until enough audio is held.
    nonisolated static func slotWindow(count: Int, rate: Double, sinceBoundary: Double, slot: Double, delay: Double = 0) -> Range<Int>? {
        let end = count - Int((sinceBoundary - delay) * rate)
        let start = end - Int(slot * rate)
        guard start >= 0, end <= count, end > start else { return nil }
        return start..<end
    }

    /// Only touched from its own queue.
    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "Vessel.ft", qos: .utility)
        private var timer: DispatchSourceTimer?
        private var tail: IQTail?
        private var demod: SSBDemod?
        private var audio: [Float] = []
        private var lastSlot: [Bool: Int] = [:]
        private var send: (([FTMessage], Int) -> Void)?
        private var log: URL?
        private let offsetLock = NSLock()
        private var offset = 0.0

        func setOffset(_ hz: Double) { offsetLock.lock(); offset = hz; offsetLock.unlock() }

        func follow(_ folder: URL?, sampleRate: Double, usb: Bool, send: @escaping ([FTMessage], Int) -> Void) {
            queue.async { [self] in
                timer?.cancel(); timer = nil
                tail = nil; demod = nil; audio = []; lastSlot = [:]
                self.send = send
                guard let folder, sampleRate > 0 else { return }
                tail = IQTail(folder: folder)
                demod = SSBDemod(inputRate: sampleRate, usb: usb)
                log = folder.appendingPathComponent("ft-messages.txt")
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 0.25, repeating: 0.25)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }

        private func tick() {
            guard let tail, demod != nil else { return }
            offsetLock.lock(); let hz = offset; offsetLock.unlock()
            demod!.offsetHz = hz
            if let iq = tail.read() { audio += demod!.process(iq) }
            let rate = demod!.outputRate
            let keep = Int(17.5 * rate)
            if audio.count > keep { audio.removeFirst(audio.count - keep) }

            let now = Date().timeIntervalSince1970
            var found: [FTMessage] = []
            var checked = 0
            for (ft4, slot) in [(true, 7.5), (false, 15.0)] {
                let index = Int(now / slot), since = now - Double(index) * slot
                // Wait a little past the boundary, as the file runs behind the air.
                guard since >= 1.5, lastSlot[ft4] != index else { continue }
                lastSlot[ft4] = index
                // FT4's decoder only tolerates about a second of timing error, so a late file gets a second look.
                var texts = Set<String>()
                var looked = false
                for delay in ft4 ? [0.0, 0.7] : [0.0] {
                    guard let range = FTMonitor.slotWindow(count: audio.count, rate: rate, sinceBoundary: since, slot: slot, delay: delay) else { continue }
                    looked = true
                    for m in FTDecoder.decode(Array(audio[range]), rate: Int(rate.rounded()), ft4: ft4, at: Date(timeIntervalSince1970: Double(index - 1) * slot))
                    where texts.insert(m.text).inserted { found.append(m) }
                }
                if looked { checked += 1 }
            }
            if checked > 0 {
                save(found)
                send?(found, checked)
            }
        }

        private func save(_ found: [FTMessage]) {
            guard let log, !found.isEmpty else { return }
            let f = ISO8601DateFormatter()
            let data = Data(found.map { "\(f.string(from: $0.time)) \($0.mode) \(Int($0.audioHz)) Hz \($0.text)\n" }.joined().utf8)
            if let h = try? FileHandle(forWritingTo: log) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
            } else {
                try? data.write(to: log)
            }
        }
    }
}

/// FT8 and FT4 messages heard, in the Receiver's Capture panel.
struct FTPanel: View {
    @ObservedObject var monitor: FTMonitor
    /// True when the tuned signal is a transponder, where these modes are used.
    let relevant: Bool
    let saving: Bool
    let callsign: String

    private var base: String { callsign.split(separator: "-").first.map(String.init) ?? "" }

    var body: some View {
        if relevant {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("FT8 and FT4").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if monitor.isFollowing {
                        Text("\(monitor.messages.count) heard, \(monitor.slotsChecked) slots").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if !monitor.isFollowing {
                    Text(saving ? "Starts with the next capture." : "Choose Save to file only to decode these. They need the raw signal.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if monitor.messages.isEmpty {
                    Label("Listening on the upper 3 kHz from the tuned frequency", systemImage: "ear")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(monitor.messages) { m in
                                HStack(spacing: 6) {
                                    Text(m.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                                    Text(m.mode).foregroundStyle(.secondary)
                                    Text("\(Int(m.audioHz))").foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                                    Text(m.text).fontWeight(!base.isEmpty && m.text.contains(base) ? .bold : .regular)
                                        .foregroundStyle(!base.isEmpty && m.text.contains(base) ? Color.orange : Color.primary)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 10, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }
}
