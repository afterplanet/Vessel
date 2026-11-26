import XCTest
@testable import Vessel

/// Real frames from HADES-SA, from AMSAT-EA's decoder (CC BY 4.0), as its decoder receives them:
/// descrambled, with the CRC still on telemetry.
private enum Sample {
    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    static let power = bytes("13D3260000000000000000E0B26D0B0030303E000001000020000000000C40")
    static let picture = bytes("A3000029140F301600CCBFDA350CF33C44C7CE473CD442469492F211F419A407C59A09771F94FCBC74C52C5F264019FAD49099199446E8C7B2B74FCEA360C646792404A9E42FF2CD202497615036AA8EBD2A3DE1942B36F41F98A7105A3CE14E3B31EB4918E3E78D429F7A0054000CA00C9D0E38348EC615F977007F8739A5792386305061FD31F9D442479DF320DC7BB77A6011AB3B642AE47A9A9542A80B9404F5209229C079518089863FC4C324523158576492939E4A8A0092286DCEE512707DF3FE1ED51B2A6C2BE71217F876F4FF0A81B6050C83096932DCC77A6711FB319FC2103FB8F34CF285BE9AF2E77160541B495D10732DA7B21E3A")
    static let voice = bytes("B31B91146A3890B2BE18F496394EFEEEC678F686CFA46A6904B88826B78493C3191BE92C2D")

    /// The telemetry frame as it went out: payload scrambled, CRC as the satellite computed it.
    static var powerOnAir: [UInt8] {
        let n = power.count
        let head: [UInt8] = [power[0]]
        let body: [UInt8] = Hades.scramble(Array(power[1..<(n - 2)]))
        let crc: [UInt8] = Array(power[(n - 2)...])
        return head + body + crc
    }
}

final class HadesFrameTests: XCTestCase {
    func testRealTelemetryPassesItsOwnCRC() {
        let f = Hades.parse(Sample.powerOnAir)
        XCTAssertEqual(f?.type, 1)
        XCTAssertEqual(f?.name, "Power")
        XCTAssertEqual(f?.crcOK, true)
        XCTAssertEqual(f?.bytes, Array(Sample.power.dropLast(2)), "descrambled back to what AMSAT-EA's decoder shows")
        var broken = Sample.powerOnAir
        broken[10] ^= 0x04
        XCTAssertNil(Hades.parse(broken), "one wrong bit fails the CRC")
    }

    func testScramblerUndoesItself() {
        let data = (0..<200).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
        XCTAssertEqual(Hades.descramble(Hades.scramble(data)), data)
        XCTAssertNotEqual(Hades.scramble(data), data)
    }

    func testRealPictureFrameIsAValidSSDVPacket() {
        let f = Hades.parse(Sample.picture)
        XCTAssertEqual(f?.type, Hades.ssdvType)
        XCTAssertNil(f?.crcOK, "pictures carry SSDV's own checks instead")
        let packet = f?.ssdvPacket ?? []
        XCTAssertEqual(packet.count, 256)
        let found = SSDVAssembler.packets(in: packet)
        XCTAssertEqual(found.count, 1, "SSDV's CRC and error correction accept the real packet")
        let a = SSDVAssembler()
        let keys = a.feed(packet)
        XCTAssertEqual(keys.count, 1)
        XCTAssertNotNil(a.jpeg(keys.first!), "one packet already gives a picture, mostly grey")
    }

    func testRealVoiceFrameDecodesToSpeech() {
        let f = Hades.parse(Sample.voice)
        XCTAssertEqual(f?.type, Hades.voiceType)
        let v = f?.voice
        XCTAssertEqual(v?.number, 27)
        XCTAssertEqual(v?.codec2.count, 35)
        let frames = Codec2.unpack(v!.codec2)
        XCTAssertEqual(frames.count, 40, "ten 700C frames of 4 bytes")
        let pcm = Codec2.decode700C(frames)
        XCTAssertEqual(pcm.count, 3200, "0.4 s at 8 kHz")
        let rms = (pcm.map { Double($0) * Double($0) }.reduce(0, +) / Double(pcm.count)).squareRoot()
        XCTAssertGreaterThan(rms, 100, "sound, not silence")
        XCTAssertLessThan(rms, 20_000)
    }

    func testOtherSatellitesAndJunkAreRefused() {
        var other = Sample.powerOnAir
        other[0] = 0x17   // same type, address 7 (URESAT-1)
        XCTAssertNil(Hades.parse(other))
        XCTAssertNil(Hades.parse(Array(Sample.powerOnAir.dropLast())), "wrong length for its type")
        XCTAssertNil(Hades.parse([]))
    }

    func testOnAirFramesAreFoundInABitStream() {
        let frames = [Hades.onAir(type: 1, payload: Array(Sample.power[1..<(Sample.power.count - 2)])),
                      [0xBF, 0x35, 0x99] + [UInt8](repeating: 0xA5, count: 30),   // a false start
                      [0x55, 0x66, 0xBF, 0x35, 0xFB] + Sample.picture,
                      [0x55, 0x55, 0xBF, 0x35, 37] + Sample.voice]
        var bits: [Bool] = []
        for byte in frames.joined() { for k in (0..<8).reversed() { bits.append(byte >> k & 1 == 1) } }
        var d = Hades.Deframer()
        let found = bits.compactMap { d.push($0) }
        XCTAssertEqual(found.map(\.type), [1, 10, 11])
        XCTAssertEqual(found.first?.bytes, Array(Sample.power.dropLast(2)))
    }
}

final class Codec2Tests: XCTestCase {
    /// A voice-like sound: a 140 Hz buzz shaped by two formants, rising and falling in level.
    private func vowel(seconds: Double) -> [Int16] {
        let n = Int(8000 * seconds)
        return (0..<n).map { i in
            let t = Double(i) / 8000
            var s = 0.0
            for h in 1...25 {
                let f = 140.0 * Double(h)
                let shape = exp(-pow((f - 700) / 200, 2)) + 0.6 * exp(-pow((f - 1200) / 250, 2)) + 0.05
                s += shape * sin(2 * .pi * f * t)
            }
            return Int16(max(-32000, min(32000, s * 6000 * (0.5 + 0.5 * sin(2 * .pi * 1.5 * t)))))
        }
    }

    func testPackingMatchesWhatTheSatelliteSends() {
        let frames = Codec2.encode700C(vowel(seconds: 0.4))
        XCTAssertEqual(frames.count, 40)
        XCTAssertTrue(stride(from: 3, to: 40, by: 4).allSatisfy { frames[$0] & 0x0F == 0 }, "28 bits used of 32")
        let packed = Codec2.pack(frames)
        XCTAssertEqual(packed.count, 35)
        XCTAssertEqual(Codec2.unpack(packed), frames)
    }

    func testSpeechSurvivesTheCodec() {
        let input = vowel(seconds: 2)
        let output = Codec2.decode700C(Codec2.encode700C(input))
        XCTAssertEqual(output.count, input.count)
        func rms(_ x: ArraySlice<Int16>) -> Double { (x.map { Double($0) * Double($0) }.reduce(0, +) / Double(x.count)).squareRoot() }
        // Codec2 rebuilds the sound rather than copying the wave, so compare loudness over time.
        let window = 800
        var a: [Double] = [], b: [Double] = []
        for s in stride(from: 1600, to: input.count - window, by: window) {
            a.append(rms(input[s..<(s + window)])); b.append(rms(output[s..<(s + window)]))
        }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        let cov = zip(a, b).map { ($0 - ma) * ($1 - mb) }.reduce(0, +)
        let corr = cov / ((a.map { pow($0 - ma, 2) }.reduce(0, +) * b.map { pow($0 - mb, 2) }.reduce(0, +)).squareRoot())
        XCTAssertGreaterThan(mb, 300, "not silent")
        XCTAssertGreaterThan(corr, 0.8, "loud where the input is loud")
    }
}

final class VoiceAssemblerTests: XCTestCase {
    func testSubframesMakeMessagesWithGapsAsSilence() {
        let v = VoiceAssembler()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let chunk = [UInt8](repeating: 0x11, count: 35)
        for n in [5, 6, 8, 9] { v.add(number: n, codec2: chunk, at: t0.addingTimeInterval(Double(n) * 0.5)) }
        XCTAssertNil(v.add(number: 6, codec2: chunk, at: t0.addingTimeInterval(5)), "a repeat is ignored")
        XCTAssertEqual(v.messages.count, 1)
        let m = v.messages[0]
        XCTAssertEqual(m.span, 5...9)
        XCTAssertEqual(m.missing, 1)
        XCTAssertEqual(m.seconds, 2.0, accuracy: 0.001)
        let pcm = VoiceAssembler.speech(m)
        XCTAssertEqual(pcm.count, 5 * 3200)
        // 5, 6, 7: the third block is the lost one.
        XCTAssertTrue(pcm[(2 * 3200)..<(3 * 3200)].allSatisfy { $0 == 0 }, "sub-frame 7 was lost, so it's silent")
        XCTAssertFalse(pcm[(3 * 3200)..<(4 * 3200)].allSatisfy { $0 == 0 }, "sub-frame 8 was not")

        // A long pause, or numbers starting again, begin a new message.
        v.add(number: 10, codec2: chunk, at: t0.addingTimeInterval(30))
        v.add(number: 0, codec2: chunk, at: t0.addingTimeInterval(31))
        XCTAssertEqual(v.messages.count, 3)
    }

    /// What the capture folder gets from a pass: the picture, the voice message, and a log.
    func testFramesBecomeFilesInTheCapture() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hades-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = [Hades.parse(Sample.powerOnAir)!, Hades.parse(Sample.picture)!] +
            (0..<4).map { n -> Hades.Frame in
                var raw = Sample.voice
                raw[1] = UInt8(27 + n)
                return Hades.parse(raw)!
            }
        let u = HadesMonitor.Worker().handle(frames, folder: folder)
        XCTAssertEqual(u.counts, ["Power": 1, "Picture": 1, "Voice": 4])
        XCTAssertEqual(u.pictures.count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertTrue(files.contains("hades-frames.txt"))
        XCTAssertTrue(files.contains { $0.hasPrefix("ssdv_") && $0.hasSuffix(".jpg") }, "\(files)")
        let voice = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("voice").path)
        XCTAssertEqual(voice.count, 1)
        XCTAssertEqual(u.voices.last?.subframes, 4)
        let wav = try Data(contentsOf: folder.appendingPathComponent("voice/\(voice[0])"))
        XCTAssertEqual(wav.count, 44 + 4 * 3200 * 2, "1.6 s of 16-bit audio at 8 kHz")
        XCTAssertFalse(files.contains { $0.hasSuffix(".wav") }, "kept out of the folder the audio monitors read")
        XCTAssertEqual(ResultClassifier.classify(name: voice[0]).title, "Voice message")
        XCTAssertEqual(ResultClassifier.classify(name: "hades-frames.txt").title, "HADES-SA frames")
    }
}

final class HadesReceiverTests: XCTestCase {
    /// HADES-SA as a receiver sees it: 800 bps FSK at 800 Hz deviation, off centre, in noise.
    private func signal(_ bytes: [UInt8], rate: Double, offset: Double, deviation: Double = 800, noise: Float = 0.3, invert: Bool = false, baud: Double = Hades.baud) -> [Float] {
        var bits: [Bool] = []
        for b in bytes { for k in (0..<8).reversed() { bits.append((b >> k & 1 == 1) != invert) } }
        let perBit = rate / baud
        var g = SystemRandomNumberGenerator()
        var iq: [Float] = []
        var phase = 0.0
        let total = Int(Double(bits.count) * perBit)
        iq.reserveCapacity(total * 2)
        for i in 0..<total {
            let bit = bits[min(bits.count - 1, Int(Double(i) / perBit))]
            phase += 2 * .pi * (offset + (bit ? deviation : -deviation)) / rate
            iq.append(Float(cos(phase)) + Float.random(in: -noise...noise, using: &g))
            iq.append(Float(sin(phase)) + Float.random(in: -noise...noise, using: &g))
        }
        return iq
    }

    private var pass: [UInt8] {
        let training = [UInt8](repeating: 0x55, count: 16)
        var out = training + Hades.onAir(type: 1, payload: Array(Sample.power[1..<(Sample.power.count - 2)]))
        out += training + [0x55, 0x66, 0xBF, 0x35, 0xFB] + Sample.picture
        for n in 0..<3 {
            var v = Sample.voice
            v[1] = UInt8(40 + n)
            out += training + [0xBF, 0x35, 37] + v
        }
        return out + training
    }

    func testFramesComeThroughTheReceiver() {
        var r = HadesReceiver(inputRate: 48_000)
        r.offsetHz = 3_500
        let found = r.process(signal(pass, rate: 48_000, offset: 3_500))
        XCTAssertEqual(found.map(\.type), [1, 10, 11, 11, 11])
        XCTAssertEqual(found.first?.bytes, Array(Sample.power.dropLast(2)))
        XCTAssertEqual(found.compactMap(\.voice?.number), [40, 41, 42])
    }

    /// The slower mode: 200 bps with 1125 Hz between the tones.
    func testTwoHundredBaudToo() {
        var r = HadesReceiver(inputRate: 48_000)
        r.offsetHz = 1_000
        let short = Array(pass.prefix(16 + 11 + Sample.power.count + 16))
        let found = r.process(signal(short, rate: 48_000, offset: 1_000, deviation: 562.5, baud: Hades.slowBaud))
        XCTAssertEqual(found.map(\.type), [1])
        XCTAssertEqual(found.first?.bytes, Array(Sample.power.dropLast(2)))
    }

    func testEitherPolarityAndSomeTuningErrorWork() {
        var r = HadesReceiver(inputRate: 250_000)
        r.offsetHz = -20_000
        // The tones the other way round, and the Doppler estimate 600 Hz out.
        let found = r.process(signal(pass, rate: 250_000, offset: -20_600, invert: true))
        XCTAssertEqual(found.map(\.type), [1, 10, 11, 11, 11])
    }

    func testFMAudioWorksToo() {
        // What the engine's FM demodulator gives: the instantaneous frequency.
        var bits: [Bool] = []
        for b in pass { for k in (0..<8).reversed() { bits.append(b >> k & 1 == 1) } }
        let rate = 48_000.0, perBit = rate / Hades.baud
        let audio = (0..<Int(Double(bits.count) * perBit)).map { i -> Float in
            (bits[min(bits.count - 1, Int(Double(i) / perBit))] ? 0.4 : -0.4) + 0.1 + Float.random(in: -0.2...0.2)
        }
        var r = HadesReceiver.audio(rate: rate)
        XCTAssertEqual(r.processAudio(audio).map(\.type), [1, 10, 11, 11, 11])
    }

    /// The live path: a raw capture file growing as the pass goes on, read the way the monitor reads it.
    func testFramesFromAGrowingCaptureFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hades-iq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("baseband.cs16")
        // Some signal from before the monitor started, which it skips.
        let early = signal([UInt8](repeating: 0x55, count: 50), rate: 96_000, offset: 2_000)
        func cs16(_ x: [Float]) -> Data { Data(x.map { Int16(max(-32767, min(32767, $0 * 12_000))) }.withUnsafeBytes { Array($0) }) }
        try cs16(early).write(to: file)
        let tail = IQTail(folder: folder)
        XCTAssertNil(tail.read(), "starts from what arrives next")
        var r = HadesReceiver(inputRate: 96_000)
        r.offsetHz = 2_000
        let live = signal(pass, rate: 96_000, offset: 2_000)
        let h = try FileHandle(forWritingTo: file)
        var found: [Hades.Frame] = []
        // Written in uneven pieces, as the engine does.
        var at = 0
        while at < live.count {
            let end = min(live.count, at + 37_002)
            _ = try h.seekToEnd(); try h.write(contentsOf: cs16(Array(live[at..<end])))
            at = end
            if let samples = tail.read() { found += r.process(samples) }
        }
        try h.close()
        XCTAssertEqual(found.map(\.type), [1, 10, 11, 11, 11])
    }

    func testNoiseAloneGivesNothing() {
        var g = SystemRandomNumberGenerator()
        let noise = (0..<(48_000 * 20 * 2)).map { _ in Float.random(in: -1...1, using: &g) }
        var r = HadesReceiver(inputRate: 48_000)
        XCTAssertTrue(r.process(noise).isEmpty)
    }
}
