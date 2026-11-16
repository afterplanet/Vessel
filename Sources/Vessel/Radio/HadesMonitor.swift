import Foundation
import SwiftUI
import AppKit
import simd
import CCodec2

/// Codec2 700C, the speech codec HADES-SA's voice messages use.
enum Codec2 {
    static let sampleRate = 8000.0
    static let samplesPerFrame = Int(CCODEC2_700C_SAMPLES)

    /// Speech from whole 4-byte frames.
    static func decode700C(_ frames: [UInt8]) -> [Int16] {
        let count = frames.count / 4
        guard count > 0 else { return [] }
        var out = [Int16](repeating: 0, count: count * samplesPerFrame)
        let n = frames.withUnsafeBufferPointer { ccodec2_decode_700c($0.baseAddress, Int32(count), &out) }
        return Array(out.prefix(Int(n)))
    }

    /// For tests: 8 kHz speech to 4-byte frames.
    static func encode700C(_ samples: [Int16]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (samples.count / samplesPerFrame) * 4)
        let n = samples.withUnsafeBufferPointer { ccodec2_encode_700c($0.baseAddress, Int32($0.count), &out) }
        return Array(out.prefix(Int(n) * 4))
    }

    /// 35 bytes carry ten 28-bit frames back to back. Codec2 keeps each in 4 bytes.
    static func unpack(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var buffer: UInt64 = 0, held = 0
        for b in bytes {
            buffer = buffer << 8 | UInt64(b); held += 8
            while held >= 28 {
                let frame = UInt32((buffer >> UInt64(held - 28)) & 0x0FFF_FFFF) << 4
                held -= 28
                out += [UInt8(frame >> 24), UInt8(frame >> 16 & 0xFF), UInt8(frame >> 8 & 0xFF), UInt8(frame & 0xFF)]
            }
        }
        return out
    }

    /// The reverse, for tests.
    static func pack(_ frames: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var buffer: UInt64 = 0, held = 0
        for i in stride(from: 0, to: frames.count - 3, by: 4) {
            let f = UInt32(frames[i]) << 24 | UInt32(frames[i + 1]) << 16 | UInt32(frames[i + 2]) << 8 | UInt32(frames[i + 3])
            buffer = buffer << 28 | UInt64(f >> 4); held += 28
            while held >= 8 { out.append(UInt8((buffer >> UInt64(held - 8)) & 0xFF)); held -= 8 }
        }
        if held > 0 { out.append(UInt8((buffer << UInt64(8 - held)) & 0xFF)) }
        return out
    }

    static func wav(_ pcm: [Int16], rate: Int = 8000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

/// Voice messages put back together from numbered sub-frames of 0.4 s each. Nothing on air
/// marks where a message ends, so a pause or a number that goes backwards starts a new one.
final class VoiceAssembler {
    struct Message: Identifiable, Equatable {
        let id: Int
        let started: Date
        var lastHeard: Date
        var subframes: [Int: [UInt8]] = [:]

        var span: ClosedRange<Int>? { subframes.keys.min().flatMap { lo in subframes.keys.max().map { lo...$0 } } }
        var missing: Int { span.map { $0.count - subframes.count } ?? 0 }
        var seconds: Double { Double(span?.count ?? 0) * 0.4 }
    }

    static let pause: TimeInterval = 8
    /// Voice frames have no checksum, so fewer than this could be chance.
    static let minimumToKeep = 3

    private(set) var messages: [Message] = []
    private var nextID = 0

    /// Returns the message the sub-frame went into, unless it was a repeat.
    @discardableResult func add(number: Int, codec2: [UInt8], at time: Date = Date()) -> Message? {
        // The same message while sub-frames keep coming and the numbers don't go back past its start.
        if var m = messages.last, time.timeIntervalSince(m.lastHeard) < Self.pause,
           let span = m.span, number >= span.lowerBound {
            guard m.subframes[number] == nil else { return nil }
            m.subframes[number] = codec2
            m.lastHeard = time
            messages[messages.count - 1] = m
            return m
        }
        var m = Message(id: nextID, started: time, lastHeard: time)
        nextID += 1
        m.subframes[number] = codec2
        messages.append(m)
        return m
    }

    /// The message as speech at 8 kHz. Lost sub-frames are silence, so the words around them stay in place.
    static func speech(_ m: Message) -> [Int16] {
        guard let span = m.span else { return [] }
        var pcm: [Int16] = []
        for n in span {
            if let bytes = m.subframes[n] { pcm += Codec2.decode700C(Codec2.unpack(bytes)) }
            else { pcm += [Int16](repeating: 0, count: 10 * Codec2.samplesPerFrame) }
        }
        return pcm
    }

    static func fileName(_ m: Message) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return "voice_\(f.string(from: m.started))_\(m.id).wav"
    }
}

/// Follows a capture of HADES-SA and decodes its telemetry, pictures and voice as they arrive.
@MainActor
final class HadesMonitor: ObservableObject {
    struct VoiceRow: Identifiable, Equatable {
        let id: Int
        let started: Date
        let subframes: Int
        let missing: Int
        let seconds: Double
        let file: URL?
    }

    @Published private(set) var isFollowing = false
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var pictures: [String: (have: Int, total: Int?)] = [:]
    @Published private(set) var voices: [VoiceRow] = []
    @Published private(set) var lastFrame: Date?

    private let worker = Worker()
    private var folder: URL?
    private var satellite: Satellite?
    private var station: Station?
    private var centreHz = 0.0
    private var timer: Timer?
    private var player: NSSound?

    var frameTotal: Int { counts.values.reduce(0, +) }

    /// `raw` is true when the capture is the raw signal, false when it is FM audio.
    func follow(_ next: URL?, raw: Bool = true, centreHz: Double = 0, sampleRate: Double = 0, satellite: Satellite? = nil, station: Station? = nil) {
        guard next != folder else { return }
        folder = next
        isFollowing = next != nil
        self.satellite = satellite?.clone()
        self.station = station
        self.centreHz = centreHz
        timer?.invalidate(); timer = nil
        if next != nil {
            counts = [:]; pictures = [:]; voices = []; lastFrame = nil
            if raw {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateDoppler() }
                }
                updateDoppler()
            }
        }
        worker.follow(next, raw: raw, sampleRate: sampleRate) { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
    }

    func play(_ row: VoiceRow) {
        guard let file = row.file else { return }
        player?.stop()
        player = NSSound(contentsOf: file, byReference: false)
        player?.play()
    }

    private func apply(_ u: Worker.Update) {
        for (k, v) in u.counts { counts[k, default: 0] += v }
        for (k, v) in u.pictures { pictures[k] = v }
        for v in u.voices {
            if let i = voices.firstIndex(where: { $0.id == v.id }) { voices[i] = v } else { voices.insert(v, at: 0) }
        }
        if u.counts.values.reduce(0, +) > 0 { lastFrame = Date() }
    }

    private func updateDoppler() {
        guard let sat = satellite, let st = station else { worker.setOffset(0); return }
        let jd = Astro.julianDate(), jd2 = jd + 1.0 / 86400
        guard let r1 = sat.position(jd: jd), let r2 = sat.position(jd: jd2) else { return }
        let g = GroundPoint(lat: st.lat, lon: st.lon)
        let rate = simd_length(Astro.ecef(r2, gmst: Astro.gmst(jd2)) - g.position) - simd_length(Astro.ecef(r1, gmst: Astro.gmst(jd)) - g.position)
        worker.setOffset(Doppler.downlink(centreHz, rangeRate: rate) - centreHz)
    }

    /// Only touched from its own queue.
    final class Worker: @unchecked Sendable {
        struct Update {
            var counts: [String: Int] = [:]
            var pictures: [String: (have: Int, total: Int?)] = [:]
            var voices: [VoiceRow] = []
        }

        private let queue = DispatchQueue(label: "Vessel.hades", qos: .utility)
        private var timer: DispatchSourceTimer?
        private var iq: IQTail?
        private var audio: WavTail?
        private var receiver: HadesReceiver?
        private var folder: URL?
        private var ssdv = SSDVAssembler()
        private var voice = VoiceAssembler()
        private var send: ((Update) -> Void)?
        private let offsetLock = NSLock()
        private var offset = 0.0

        func setOffset(_ hz: Double) { offsetLock.lock(); offset = hz; offsetLock.unlock() }

        func follow(_ folder: URL?, raw: Bool, sampleRate: Double, send: @escaping (Update) -> Void) {
            queue.async { [self] in
                if let f = self.folder { finish(in: f) }
                timer?.cancel(); timer = nil
                iq = nil; audio = nil; receiver = nil
                ssdv = SSDVAssembler(); voice = VoiceAssembler()
                self.folder = folder
                self.send = send
                guard let folder else { return }
                if raw {
                    guard sampleRate > 0 else { return }
                    iq = IQTail(folder: folder)
                    receiver = HadesReceiver(inputRate: sampleRate)
                } else {
                    audio = WavTail(folder: folder)
                }
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 0.25, repeating: 0.25)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }

        private func tick() {
            guard let folder else { return }
            var frames: [Hades.Frame] = []
            if let iq, let samples = iq.read() {
                offsetLock.lock(); receiver?.offsetHz = offset; offsetLock.unlock()
                frames = receiver?.process(samples) ?? []
            } else if let audio, let samples = audio.read(), let format = audio.format {
                if receiver == nil { receiver = HadesReceiver.audio(rate: format.sampleRate) }
                frames = receiver?.processAudio(samples) ?? []
            }
            guard !frames.isEmpty else { return }
            send?(handle(frames, folder: folder))
        }

        /// Exposed for tests: what a batch of frames does to the capture folder.
        func handle(_ frames: [Hades.Frame], folder: URL, at time: Date = Date()) -> Update {
            var u = Update()
            var log = ""
            let stamp = ISO8601DateFormatter().string(from: time)
            for f in frames {
                u.counts[f.name, default: 0] += 1
                log += "\(stamp) \(f.name) \(f.bytes.map { String(format: "%02X", $0) }.joined())\n"
                if let packet = f.ssdvPacket {
                    for key in ssdv.feed(packet) {
                        if let jpeg = ssdv.jpeg(key) {
                            try? jpeg.write(to: folder.appendingPathComponent(SSDVAssembler.fileName(key)), options: .atomic)
                        }
                        let p = ssdv.pictures[key]!
                        u.pictures[SSDVAssembler.fileName(key)] = (p.packets.count, p.total)
                    }
                }
                if let v = f.voice, let m = voice.add(number: v.number, codec2: v.codec2, at: time) {
                    u.voices.append(save(m, in: folder))
                }
            }
            append(log, to: folder.appendingPathComponent("hades-frames.txt"))
            return u
        }

        private func save(_ m: VoiceAssembler.Message, in folder: URL) -> VoiceRow {
            var file: URL?
            if m.subframes.count >= VoiceAssembler.minimumToKeep {
                // In a folder of its own, so the capture's own audio is never mistaken for it.
                let dir = folder.appendingPathComponent("voice", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(VoiceAssembler.fileName(m))
                if (try? Codec2.wav(VoiceAssembler.speech(m)).write(to: url, options: .atomic)) != nil { file = url }
            }
            return VoiceRow(id: m.id, started: m.started, subframes: m.subframes.count, missing: m.missing, seconds: m.seconds, file: file)
        }

        private func finish(in folder: URL) {
            if let iq, let samples = iq.read(), let frames = receiver?.process(samples), !frames.isEmpty {
                send?(handle(frames, folder: folder))
            }
        }

        private func append(_ text: String, to url: URL) {
            let data = Data(text.utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// HADES-SA's frames, pictures and voice, in the Receiver's Capture panel.
struct HadesPanel: View {
    @ObservedObject var monitor: HadesMonitor
    let relevant: Bool
    let saving: Bool

    var body: some View {
        if relevant {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("HADES-SA data").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if monitor.isFollowing {
                        Text("\(monitor.frameTotal) frames").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if !monitor.isFollowing {
                    Text(saving ? "Starts with the next capture." : "Choose Save to file only to decode its telemetry, pictures and voice.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if monitor.frameTotal == 0 {
                    Label("Listening for 800 and 200 bps frames", systemImage: "ear")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(monitor.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(monitor.pictures.keys.sorted(), id: \.self) { name in
                        let p = monitor.pictures[name]!
                        Label("\(name): \(p.have)\(p.total.map { " of \($0)" } ?? "") packets", systemImage: "photo")
                            .font(.system(size: 10))
                    }
                    ForEach(monitor.voices) { v in
                        HStack(spacing: 6) {
                            Button { monitor.play(v) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless).disabled(v.file == nil)
                                .help(v.file == nil ? "Kept once \(VoiceAssembler.minimumToKeep) sub-frames have arrived" : "Play this message")
                            Text("Voice \(v.started.formatted(date: .omitted, time: .standard))")
                            Text(String(format: "%.1f s, %d sub-frames%@", v.seconds, v.subframes, v.missing > 0 ? ", \(v.missing) lost" : ""))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10))
                    }
                }
            }
        }
    }
}
