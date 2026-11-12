import AVFoundation
import Foundation

/// The parts of a WAV file needed to read one that's still being written.
struct WavFormat: Equatable {
    let sampleRate: Double
    let channels: Int
    let dataOffset: UInt64

    var frameBytes: Int { channels * 2 }

    /// 16-bit PCM only, which is what the engine writes. The sizes in the header can't be trusted
    /// while the file is growing, so only the chunks' positions are used.
    static func parse(_ d: Data) -> WavFormat? {
        let b = [UInt8](d)
        guard b.count >= 12, b[0...3].elementsEqual("RIFF".utf8), b[8...11].elementsEqual("WAVE".utf8) else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var i = 12
        var rate = 0.0, channels = 0
        while i + 8 <= b.count {
            let size = u32(i + 4)
            if b[i..<(i + 4)].elementsEqual("fmt ".utf8) {
                guard i + 24 <= b.count, u16(i + 8) == 1, u16(i + 22) == 16 else { return nil }
                channels = u16(i + 10)
                rate = Double(u32(i + 12))
            } else if b[i..<(i + 4)].elementsEqual("data".utf8) {
                guard rate > 0, channels > 0 else { return nil }
                return WavFormat(sampleRate: rate, channels: channels, dataOffset: UInt64(i + 8))
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// The first channel, as -1...1.
    static func samples(_ d: Data, channels: Int) -> [Float] {
        let step = channels * 2
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            stride(from: 0, to: raw.count - step + 1, by: step).map { i in
                Float(raw.loadUnaligned(fromByteOffset: i, as: Int16.self).littleEndian) / 32768
            }
        }
    }
}

/// Plays the audio the engine is writing, a moment behind live. Nothing touches the sound
/// output unless it's following a folder, so muted really is silent.
final class AudioMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Vessel.audio")
    private var folder: URL?
    private var timer: DispatchSourceTimer?
    private var file: FileHandle?
    private var format: WavFormat?
    private var offset: UInt64 = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pcm: AVAudioFormat?
    /// Audio handed to the player and not yet heard.
    private var queuedSeconds = 0.0
    private var failed = false

    static let leadSeconds = 0.3
    static let furthestBehindSeconds = 2.0

    /// For checking the path without sound: replaces the speakers with this.
    var testSink: (@Sendable ([Float], Double) -> Void)?

    /// `folder` is where to look for a WAV file, or nil to go silent.
    func follow(_ next: URL?) {
        queue.async { [self] in
            guard next != folder else { return }
            shutDown()
            folder = next
            guard next != nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 0.1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    private func shutDown() {
        timer?.cancel(); timer = nil
        player?.stop()
        engine?.stop()
        engine = nil; player = nil; pcm = nil
        try? file?.close()
        file = nil; format = nil
        queuedSeconds = 0
        failed = false
    }

    private func tick() {
        guard !failed else { return }
        if file == nil, !open() { return }
        guard let file, let format, let end = try? file.seekToEnd() else { return }
        let frame = UInt64(format.frameBytes)
        let bytesPerSecond = format.sampleRate * Double(frame)
        // Fell behind, or just unmuted: pick up near live rather than playing the past.
        if Double(end - min(end, offset)) > bytesPerSecond * Self.furthestBehindSeconds {
            offset = Self.liveEdge(end: end, format: format)
        }
        let available = (end - min(end, offset)) / frame * frame
        guard available > 0 else { return }
        guard (try? file.seek(toOffset: offset)) != nil, let data = try? file.read(upToCount: Int(available)), !data.isEmpty else { return }
        offset += UInt64(data.count) / frame * frame
        play(WavFormat.samples(data, channels: format.channels), rate: format.sampleRate)
    }

    private func open() -> Bool {
        guard let folder,
              let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let wav = names.first(where: { $0.pathExtension.lowercased() == "wav" }),
              let handle = try? FileHandle(forReadingFrom: wav),
              let head = try? handle.read(upToCount: 256), let parsed = WavFormat.parse(head),
              let end = try? handle.seekToEnd() else { return false }
        file = handle
        format = parsed
        offset = Self.liveEdge(end: end, format: parsed)
        return true
    }

    /// A little before the end of the file, on a frame boundary.
    static func liveEdge(end: UInt64, format: WavFormat) -> UInt64 {
        guard end > format.dataOffset else { return format.dataOffset }
        let frame = UInt64(format.frameBytes)
        let back = UInt64(format.sampleRate * leadSeconds) * frame
        let frames = (end - format.dataOffset) / frame
        return format.dataOffset + (frames * frame - min(frames * frame, back))
    }

    private func play(_ samples: [Float], rate: Double) {
        guard startEngine(rate: rate), let player, let pcm,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let seconds = Double(samples.count) / rate
        queuedSeconds += seconds
        player.scheduleBuffer(buffer) { [weak self, weak player] in
            self?.queue.async {
                guard let self, player === self.player else { return }
                self.queuedSeconds = max(0, self.queuedSeconds - seconds)
                // Ran dry: wait for a little in hand again, so a slow network doesn't stutter.
                if self.queuedSeconds == 0 { player?.pause() }
            }
        }
        if !player.isPlaying, queuedSeconds >= Self.leadSeconds { player.play() }
    }

    private func startEngine(rate: Double) -> Bool {
        if engine != nil { return true }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { failed = true; return false }
        let e = AVAudioEngine(), p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        if let testSink {
            e.mainMixerNode.outputVolume = 0
            p.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, _ in
                guard let c = buffer.floatChannelData?[0] else { return }
                testSink(Array(UnsafeBufferPointer(start: c, count: Int(buffer.frameLength))), rate)
            }
        }
        do {
            try e.start()
        } catch {
            failed = true
            return false
        }
        engine = e; player = p; pcm = format
        return true
    }
}
