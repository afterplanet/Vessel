import XCTest
@testable import Vessel

private func tx(service: String = "Amateur", kind: String = "Transceiver", desc: String = "FM Voice Repeater",
                low: Double? = 145_990_000, high: Double? = nil, mode: String = "FM", active: Bool = true,
                coordination: String = "IARU Coordinated", violation: Bool = false, inverted: Bool = false,
                dlLow: Double = 437_800_000, dlHigh: Double? = nil) -> Transmitter {
    Transmitter(description: desc, downlinkHz: dlLow, mode: mode, active: active, baud: nil, downlinkHighHz: dlHigh,
                uplinkLowHz: low, uplinkHighHz: high, uplinkMode: mode, inverted: inverted, service: service, kind: kind,
                coordination: coordination, frequencyViolation: violation)
}

final class UplinkPolicyTests: XCTestCase {
    func testPublicAmateurUplinksAreAllowed() {
        XCTAssertEqual(UplinkPolicy.evaluate(tx()), .allowed)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(kind: "Transponder", desc: "Mode U/V Linear", low: 435_130_000, high: 435_150_000, mode: "LSB")), .allowed)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(desc: "Mode V/V APRS digipeater", low: 145_825_000, mode: "AFSK")), .allowed)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(desc: "Mode U/V FM Voice (no CTCSS any longer)", low: 435_250_000, coordination: "N/A")), .allowed)
    }

    func testEveryNonAmateurServiceIsRefused() {
        for s in ["", "Unknown", "Space Operation", "Earth Exploration", "Space Research", "Military", "Meteorological"] {
            XCTAssertEqual(UplinkPolicy.evaluate(tx(service: s)), .notAmateur, s)
        }
    }

    func testCommandAndTelemetryLinksAreRefused() {
        for d in ["DOWN: CW in FM, UP: DTMF commands", "Mode V/U - BPSK9k6 - AX.25 G3RUH - TC", "Telemetry GMSK9k6 AX.25",
                  "Telecommand repeater", "Mode U Beacon", "Mode U/U - LoRa - Ping Reply", "Message Exchange + Camera Downlink"] {
            XCTAssertEqual(UplinkPolicy.evaluate(tx(desc: d)), .notPublic, d)
        }
        XCTAssertEqual(UplinkPolicy.evaluate(tx(desc: "AstroDev Li-2", mode: "GMSK")), .notPublic)
    }

    func testFrequenciesOutsideTheSubBandsAreRefused() {
        for f in [29_472_000.0, 144_500_000, 146_500_000, 433_000_000, 440_000_000, 1_240_000_000, 21_125_000, 13_820] {
            XCTAssertEqual(UplinkPolicy.evaluate(tx(low: f)), .outsideSubBand, "\(f)")
        }
        // A passband poking out of the band is refused too, even if it starts inside.
        XCTAssertEqual(UplinkPolicy.evaluate(tx(low: 145_990_000, high: 146_100_000)), .outsideSubBand)
    }

    func testBadStandingIsRefused() {
        XCTAssertEqual(UplinkPolicy.evaluate(tx(active: false)), .inactive)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(violation: true)), .flaggedViolation)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(coordination: "IARU Declined")), .uncoordinated)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(coordination: "IARU Uncoordinated")), .uncoordinated)
        XCTAssertEqual(UplinkPolicy.evaluate(tx(low: nil)), .noUplink)
    }

    func testAllReasonsAreListedForARefusedUplink() {
        // CAS-2T's FM transponder, as SatNOGS lists it.
        let cas = tx(desc: "FM Transponder", low: 145_925_000, mode: "FMN", active: false, coordination: "IARU Uncoordinated", violation: true, dlLow: 435_615_000)
        XCTAssertNotEqual(UplinkPolicy.evaluate(cas), .allowed)
        XCTAssertEqual(UplinkPolicy.problems(cas), [.inactive, .flaggedViolation, .uncoordinated])
        XCTAssertEqual(UplinkPolicy.problems(tx()), [], "an allowed uplink has nothing against it")
        XCTAssertEqual(UplinkPolicy.problems(tx(service: "Unknown", desc: "Telecommand", low: 2_025_000_000)), [.notAmateur, .outsideSubBand, .notPublic])
        for r in [Eligibility.notAmateur, .inactive, .outsideSubBand, .flaggedViolation, .uncoordinated, .notPublic, .noUplink] {
            XCTAssertFalse(r.explanation.isEmpty)
        }
    }

    func testModesMatchWhatTheUplinkCarries() {
        XCTAssertEqual(UplinkPolicy.make(tx())?.modes, [.fmVoice])
        XCTAssertEqual(UplinkPolicy.make(tx(kind: "Transponder", desc: "Linear", low: 435_100_000, high: 435_120_000, mode: "LSB"))?.modes, [.ssbVoice, .cw, .psk31, .rtty, .ft8, .ft4])
        XCTAssertEqual(UplinkPolicy.make(tx(kind: "Transponder", desc: "CW Transponder", low: 435_100_000, high: 435_120_000, mode: "CW"))?.modes, [.cw])
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "APRS Digipeater", mode: "AFSK"))?.modes, [.aprs, .aprsPosition, .packet1200])
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "Mode V/V - GFSK9k6 - Digipeater - AX.25", mode: "GFSK"))?.modes, [.packet9600])
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "Mode V/V - FSK9k6 - Digipeater - AX.25 G3RUH", mode: "FSK"))?.modes, [.packet9600])
        // Framing that an AX.25 signal would not reach, or that the listing doesn't state.
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "Digipeater (Mobitex, idle mode)", mode: "GMSK"))?.modes, [])
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "Mode U/U - GMSK9k6 - Digipeater - Skylink", mode: "GMSK"))?.modes, [])
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "Mode U/U - GFSK2k4 Repeater", mode: "GFSK"))?.modes, [])
        XCTAssertEqual(UplinkPolicy.make(tx(desc: "Mode V/V Digipeater", mode: "FSK AX.100 Mode 5"))?.modes, [])
    }

    func testCTCSS() {
        XCTAssertEqual(UplinkPolicy.ctcss(in: "Mode V/U FM - Voice Repeater CTCSS 67.0 Hz"), 67.0)
        XCTAssertEqual(UplinkPolicy.ctcss(in: "SSDV (PL 88.5Hz)"), 88.5)
        XCTAssertEqual(UplinkPolicy.ctcss(in: "Mode V/U FM 67.0 PL"), 67.0)
        XCTAssertNil(UplinkPolicy.ctcss(in: "Mode U/V FM Voice (no CTCSS any longer)"))
        XCTAssertNil(UplinkPolicy.ctcss(in: "Mode V/U FM"))
    }

    func testEverySignalStaysInsideItsPassband() {
        for mode in [TxMode.ssbVoice, .cw, .psk31, .rtty, .ft8, .ft4] {
            for name in ["USB", "LSB"] {
                let u = UplinkPolicy.make(tx(kind: "Transponder", desc: "Linear", low: 435_100_000, high: 435_120_000, mode: name))!
                for p in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let s = u.signalHz(position: p, mode: mode)
                    XCTAssertGreaterThanOrEqual(s - mode.halfBandwidthHz, u.lowHz, "\(mode) \(name) \(p)")
                    XCTAssertLessThanOrEqual(s + mode.halfBandwidthHz, u.highHz, "\(mode) \(name) \(p)")
                    // The audio tone on that dial, in that sideband, lands on the signal.
                    let d = u.dialHz(position: p, mode: mode)
                    XCTAssertEqual(name == "USB" ? d + mode.audioCentreHz : d - mode.audioCentreHz, s, accuracy: 0.01)
                }
            }
        }
    }

    func testSingleFrequencyUplinksIgnoreOffsets() {
        let u = UplinkPolicy.make(tx())!
        XCTAssertEqual(u.dialHz(position: 0.9, mode: .fmVoice), 145_990_000)
        XCTAssertEqual(u.dialHz(position: 0.1, mode: .packet9600), 145_990_000)
    }

    func testLinearTuningStaysInThePassbandAndInverts() {
        let u = UplinkPolicy.make(tx(kind: "Transponder", desc: "Linear", low: 435_100_000, high: 435_120_000, mode: "LSB", inverted: true, dlLow: 145_855_000, dlHigh: 145_875_000))!
        XCTAssertEqual(u.nominalUplink(position: 0), 435_100_000)
        XCTAssertEqual(u.nominalDownlink(position: 0), 145_875_000)
        XCTAssertEqual(u.nominalUplink(position: 1), 435_120_000)
        XCTAssertEqual(u.nominalDownlink(position: 1), 145_855_000)
        XCTAssertEqual(u.nominalUplink(position: 5), 435_120_000)
        XCTAssertEqual(u.nominalUplink(position: -5), 435_100_000)
    }
}

final class DopplerAndCallsignTests: XCTestCase {
    func testDopplerSigns() {
        // Approaching at 7 km/s on 437 MHz: heard about 10 kHz high, so transmit about 10 kHz low.
        let d = Doppler.downlink(437_000_000, rangeRate: -7), u = Doppler.uplink(437_000_000, rangeRate: -7)
        XCTAssertEqual(d - 437_000_000, 10_204, accuracy: 5)
        XCTAssertEqual(u - 437_000_000, -10_204, accuracy: 5)
        // What the satellite hears must land back on the nominal frequency.
        XCTAssertEqual(Doppler.downlink(Doppler.uplink(145_990_000, rangeRate: 5), rangeRate: 5), 145_990_000, accuracy: 1)
    }

    func testCallsigns() {
        for c in ["W1AW", "VU2ABC", "G4XYZ", "9V1XY", "N0CALL", "KB1ABC-7", "2E0ABC"] { XCTAssertTrue(Callsign.isValid(c), c) }
        for c in ["", "HELLO", "12345", "W1", "w1aw", "W1AW ", "W1AW-123"] { XCTAssertFalse(Callsign.isValid(c), c) }
    }
}

final class TxChecksTests: XCTestCase {
    private let good = TxChecks(callsign: "W1AW", licenceConfirmed: true, sourceKind: .usb,
                                station: Station(name: "Home", lat: 1, lon: 2, iso: "us"), radioConnected: true,
                                uplink: UplinkPolicy.make(tx()), mode: .fmVoice, elevation: 40, minElevation: 10,
                                elementAgeDays: 1, audioReady: true)

    func testAllGood() { XCTAssertTrue(good.allPass) }

    func testEachConditionBlocksOnItsOwn() {
        var c: TxChecks
        c = good; c.callsign = ""; XCTAssertFalse(c.allPass)
        c = good; c.licenceConfirmed = false; XCTAssertFalse(c.allPass)
        c = good; c.sourceKind = .spy; XCTAssertFalse(c.allPass)
        c = good; c.sourceKind = .network; XCTAssertFalse(c.allPass)
        c = good; c.station = nil; XCTAssertFalse(c.allPass)
        c = good; c.station?.fromSpyHost = true; XCTAssertFalse(c.allPass)
        c = good; c.radioConnected = false; XCTAssertFalse(c.allPass)
        c = good; c.uplink = nil; XCTAssertFalse(c.allPass)
        c = good; c.mode = .aprs; XCTAssertFalse(c.allPass) // this uplink is FM voice only
        c = good; c.mode = nil; XCTAssertFalse(c.allPass)
        c = good; c.elevation = 9.9; XCTAssertFalse(c.allPass)
        c = good; c.elevation = nil; XCTAssertFalse(c.allPass)
        c = good; c.elementAgeDays = 8; XCTAssertFalse(c.allPass)
        c = good; c.elementAgeDays = nil; XCTAssertFalse(c.allPass)
        c = good; c.audioReady = false; XCTAssertFalse(c.allPass)
    }
}

final class DigitalModeTests: XCTestCase {
    func testVaricodeIsWellFormed() {
        let codes = Array(AudioSignals.varicode.values)
        XCTAssertEqual(Set(codes).count, codes.count, "codes are unique")
        for c in codes {
            XCTAssertFalse(c.contains("00"), c)
            XCTAssertTrue(c.hasPrefix("1") && c.hasSuffix("1"), c)
        }
        XCTAssertEqual(AudioSignals.varicode["e"], "11")
        XCTAssertEqual(AudioSignals.varicode[" "], "1")
    }

    /// A small coherent demodulator: compares phase at symbol boundaries, then splits on "00".
    private func decodePSK31(_ s: [Float]) -> String {
        let n = Int(AudioSignals.sampleRate / 31.25), w = 48 * 4
        var previous: Double?
        var bits: [Bool] = []
        var i = 0
        while i + w / 2 < s.count {
            if i >= w / 2 {
                var acc = 0.0
                for k in (i - w / 2)..<(i + w / 2) {
                    acc += Double(s[k]) * sin(2 * .pi * 1000 * Double(k) / AudioSignals.sampleRate)
                }
                if let p = previous { bits.append(p * acc > 0) }
                previous = acc
            }
            i += n
        }
        var reverse: [String: Character] = [:]
        for (k, v) in AudioSignals.varicode { reverse[v] = k }
        var out = "", word = ""
        for b in bits.map({ $0 ? "1" : "0" }).joined().components(separatedBy: "00") {
            word = b.trimmingCharacters(in: CharacterSet(charactersIn: "0"))
            if let c = reverse[word] { out.append(c) }
        }
        return out
    }

    func testPSK31DecodesBack() {
        let text = "CQ de N0CALL: Test 123, pse k"
        XCTAssertTrue(decodePSK31(AudioSignals.psk31(text: text)).contains(text), decodePSK31(AudioSignals.psk31(text: text)))
    }

    func testBaudotShifts() {
        XCTAssertEqual(AudioSignals.baudot("E1E"), [31, 31, 1, 27, 23, 31, 1])
        XCTAssertEqual(AudioSignals.baudot("A B"), [31, 31, 3, 4, 25])
    }

    func testFT8AndFT4Durations() {
        let f8 = AudioSignals.ftx(text: "CQ N0CALL FN31", ft4: false)
        let f4 = AudioSignals.ftx(text: "CQ N0CALL FN31", ft4: true)
        XCTAssertEqual(Double(f8?.count ?? 0) / AudioSignals.sampleRate, 12.64, accuracy: 0.01)
        XCTAssertEqual(Double(f4?.count ?? 0) / AudioSignals.sampleRate, 5.04, accuracy: 0.02)
    }

    /// Strongest of the candidate tones during one symbol, by direct correlation.
    private func tone(_ s: [Float], start: Int, length: Int, base: Double, spacing: Double, count: Int) -> Int {
        var best = 0, bestPower = -1.0
        for k in 0..<count {
            let w = 2 * Double.pi * (base + Double(k) * spacing) / AudioSignals.sampleRate
            var re = 0.0, im = 0.0
            for i in start..<min(start + length, s.count) {
                re += Double(s[i]) * cos(w * Double(i)); im += Double(s[i]) * sin(w * Double(i))
            }
            if re * re + im * im > bestPower { bestPower = re * re + im * im; best = k }
        }
        return best
    }

    func testFT8SyncPatternIsOnAir() {
        let s = AudioSignals.ftx(text: "CQ N0CALL FN31", ft4: false)!
        let n = Int(0.16 * AudioSignals.sampleRate)
        let costas = [3, 1, 4, 0, 6, 5, 2]
        for block in [0, 36, 72] {
            let seen = (0..<7).map { tone(s, start: (block + $0) * n + n / 4, length: n / 2, base: 1500, spacing: 6.25, count: 8) }
            XCTAssertEqual(seen, costas, "block at symbol \(block)")
        }
    }

    func testFT4SyncPatternIsOnAir() {
        let s = AudioSignals.ftx(text: "CQ N0CALL FN31", ft4: true)!
        let n = Int(0.048 * AudioSignals.sampleRate)
        for (block, pattern) in [(1, [0, 1, 3, 2]), (34, [1, 0, 2, 3]), (67, [2, 3, 1, 0]), (100, [3, 2, 0, 1])] {
            let seen = (0..<4).map { tone(s, start: (block + $0) * n + n / 4, length: n / 2, base: 1500, spacing: 20.833, count: 4) }
            XCTAssertEqual(seen, pattern, "block at symbol \(block)")
        }
    }

    func testMessageRules() {
        XCTAssertNil(TxSignal.problem(mode: .ft8, message: "CQ N0CALL FN31", callsign: "N0CALL"))
        XCTAssertNil(TxSignal.problem(mode: .ft8, message: "cq n0call fn31", callsign: "N0CALL-7"))
        XCTAssertNotNil(TxSignal.problem(mode: .ft8, message: "CQ W1AW FN31", callsign: "N0CALL"), "someone else's callsign")
        XCTAssertNotNil(TxSignal.problem(mode: .ft4, message: "", callsign: "N0CALL"))
        XCTAssertNotNil(TxSignal.problem(mode: .psk31, message: "  ", callsign: "N0CALL"))
        XCTAssertNil(TxSignal.problem(mode: .fmVoice, message: "", callsign: "N0CALL"))
    }

    func testPlainTextIdentifies() {
        XCTAssertEqual(TxSignal.identified("CQ CQ", callsign: "N0CALL-7"), "CQ CQ DE N0CALL")
        XCTAssertEqual(TxSignal.identified("cq de n0call", callsign: "N0CALL"), "cq de n0call")
    }

    func testMaidenhead() {
        XCTAssertEqual(Maidenhead.locator(lat: 41.71, lon: -72.73), "FN31")
        XCTAssertEqual(Maidenhead.locator(lat: 12.97, lon: 77.57), "MK82")
        XCTAssertEqual(Maidenhead.locator(lat: -33.87, lon: 151.21), "QF56")
    }

    func testRendersNothingForAnInvalidMessage() {
        XCTAssertNil(TxSignal.render(mode: .ft8, message: "CQ W1AW FN31", callsign: "N0CALL", path: [], usb: true))
    }
}

final class OrbitClassTests: XCTestCase {
    private func c(_ p: Double, _ i: Double, _ e: Double) -> OrbitClass {
        OrbitClass.classify(periodMinutes: p, inclination: i, eccentricity: e)
    }

    func testRealOrbits() {
        XCTAssertEqual(c(92.9, 51.6, 0.0004), .leo, "ISS")
        XCTAssertEqual(c(95, 53, 0.0001), .leo, "Starlink")
        XCTAssertEqual(c(99, 98.2, 0.001), .sso, "Landsat")
        XCTAssertEqual(c(718, 55, 0.01), .meo, "GPS")
        XCTAssertEqual(c(287, 0.03, 0.0002), .meo, "O3B")
        XCTAssertEqual(c(1436, 0.05, 0.0002), .geo, "GOES")
        XCTAssertEqual(c(1436, 41, 0.07), .geo, "QZSS")
        XCTAssertEqual(c(718, 63.4, 0.72), .heo, "Molniya")
        XCTAssertEqual(c(640, 27, 0.7), .heo, "transfer orbit")
        XCTAssertEqual(c(19700, 37, 0.54), .deep, "TESS")
    }

    func testPolarButHighIsNotSunSynchronous() {
        XCTAssertEqual(c(99, 90, 0.001), .leo)
        XCTAssertEqual(c(140, 99, 0.001), .meo)
        XCTAssertEqual(c(100, 99, 0.2), .leo)
    }

    func testEveryClassHasItsOwnColour() {
        XCTAssertEqual(Set(OrbitClass.allCases.map { Palette.color($0) }).count, OrbitClass.allCases.count)
    }
}

final class PipelineRateTests: XCTestCase {
    func testFindsTheFastestSymbolRate() {
        let work: [String: Any] = ["soft": ["module": "psk_demod", "parameters": ["symbolrate": 72000]],
                                   "cadu": ["module": "x", "parameters": ["other": 5, "nested": ["symbolrate": 665400]]]]
        XCTAssertEqual(PipelineCatalog.fastestSymbolRate(in: work), 665400)
        XCTAssertNil(PipelineCatalog.fastestSymbolRate(in: ["a": 1]))
    }

    func testPreferredRate() {
        func p(_ s: Double?, _ y: Double?) -> Pipeline { Pipeline(id: "x", name: "x", frequenciesHz: [], samplerate: s, liveCapable: true, symbolRate: y) }
        XCTAssertEqual(p(3e6, 665_400).preferredRate, 3e6, "its own setting wins")
        XCTAssertEqual(p(nil, 72_000).preferredRate, 1e6, "never below 1 MS/s")
        XCTAssertEqual(p(nil, 2_000_000).preferredRate, 5e6, "enough for the symbols")
    }
}

final class ResultClassifierTests: XCTestCase {
    private func k(_ n: String) -> ResultKind { ResultClassifier.classify(name: n).kind }

    func testIdentifiesFiles() {
        for n in ["msu_mr_rgb_221.png", "a.JPG", "b.tiff"] { XCTAssertEqual(k(n), .image, n) }
        for n in ["dataset.json", "telemetry.json", "x.txt", "y.csv", "z.log"] { XCTAssertEqual(k(n), .readable, n) }
        XCTAssertEqual(k("analog_demod_25544_145825000Hz.wav"), .audio)
        XCTAssertEqual(k("baseband.wav"), .baseband)
        for n in ["baseband.cs16", "a.cf32", "b.ziq"] { XCTAssertEqual(k(n), .baseband, n) }
        for n in ["meteor_m2-x_lrpt.cadu", "a.soft", "b.frm"] { XCTAssertEqual(k(n), .decodedData, n) }
        XCTAssertEqual(k("product.cbor"), .product)
        XCTAssertEqual(k("mystery.xyz"), .other)
    }

    func testOnlyPreviewableKindsAreViewable() {
        XCTAssertTrue(ResultKind.image.isViewable && ResultKind.readable.isViewable && ResultKind.audio.isViewable)
        XCTAssertFalse(ResultKind.baseband.isViewable || ResultKind.decodedData.isViewable || ResultKind.product.isViewable)
    }

    func testSessionInfoRoundTripAndOldFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = dir.appendingPathComponent("ISS_ZARYA__2026-11-04T05-17-39Z")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(count: 100).write(to: old.appendingPathComponent("a.wav"))
        XCTAssertEqual(ResultClassifier.session(at: old)?.title, "ISS ZARYA", "folders from before session files still read")
        XCTAssertEqual(ResultClassifier.session(at: old)?.outcome, "Audio saved")

        let info = SessionInfo(satellite: "X", norad: 1, frequencyHz: 1e6, sampleRate: 1e6, pipelineName: nil, decoding: false, source: "S", host: nil, started: Date(timeIntervalSince1970: 1000), ended: nil)
        let new = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        info.write(to: new)
        XCTAssertEqual(SessionInfo.read(from: new), info)
        XCTAssertEqual(ResultClassifier.session(at: new)?.files.count, 0, "its own record isn't a result")
        XCTAssertEqual(ResultClassifier.session(at: new)?.outcome, "Nothing decoded. The signal may have been too weak.")
    }

    func testOutcomeLeadsWithTheBestResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 100).write(to: dir.appendingPathComponent("baseband.cs16"))
        XCTAssertEqual(ResultClassifier.session(at: dir)?.outcome, "Saved the raw signal, ready for decoding later")
        try Data(count: 100).write(to: dir.appendingPathComponent("frames.cadu"))
        XCTAssertEqual(ResultClassifier.session(at: dir)?.outcome, "Frames decoded, with no images")
        try Data(count: 100).write(to: dir.appendingPathComponent("a.png"))
        try Data(count: 100).write(to: dir.appendingPathComponent("b.png"))
        XCTAssertEqual(ResultClassifier.session(at: dir)?.outcome, "2 images decoded")
    }

    func testEmptyProductsDontCountAsAResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("m.cadu"))
        try Data(count: 96).write(to: dir.appendingPathComponent("dataset.json"))
        try Data(count: 4).write(to: dir.appendingPathComponent("telemetry.json"))
        try Data(count: 421).write(to: dir.appendingPathComponent("product.cbor"))
        XCTAssertTrue(ResultClassifier.session(at: dir)?.outcome.hasPrefix("Nothing decoded") == true)
    }
}

final class PipelineLogicTests: XCTestCase {
    private let rules = [
        PipelineRules.Rule(match: "^TERRA$", pipelines: ["terra_db"]),
        PipelineRules.Rule(match: "^METEOR-M2 [34]\\b", pipelines: ["slow_one", "meteor_lrpt"], frequencyMHz: 137.9),
    ]

    func testRuleBoundaries() {
        XCTAssertNotNil(PipelineRules.rule(for: "TERRA", in: rules))
        XCTAssertNil(PipelineRules.rule(for: "TERRASAR-X", in: rules))
        XCTAssertNil(PipelineRules.rule(for: "TERRA NOVA", in: rules))
        XCTAssertNotNil(PipelineRules.rule(for: "METEOR-M2 4", in: rules))
        XCTAssertNil(PipelineRules.rule(for: "METEOR-M2 2", in: rules))
    }

    func testNameMatchNeedsTheWholeIdentity() {
        XCTAssertTrue(PipelineCatalog.nameMatches(satellite: "COSMOS 2558", pipelineName: "Cosmos 2558 S-Band Dump"))
        XCTAssertFalse(PipelineCatalog.nameMatches(satellite: "COSMOS 2385", pipelineName: "Cosmos 2558 S-Band Dump"))
        XCTAssertFalse(PipelineCatalog.nameMatches(satellite: "COSMOS 25581", pipelineName: "Cosmos 2558 S-Band Dump"))
        XCTAssertTrue(PipelineCatalog.nameMatches(satellite: "JASON-3", pipelineName: "Jason-3 S-Band Link"))
        XCTAssertTrue(PipelineCatalog.nameMatches(satellite: "CHEOPS", pipelineName: "CHEOPS S-Band Dump"))
        XCTAssertFalse(PipelineCatalog.nameMatches(satellite: "TERRASAR-X", pipelineName: "Terra DB"))
        XCTAssertFalse(PipelineCatalog.nameMatches(satellite: "AWS-1", pipelineName: "AWS PFM L-Band"), "too short an identity to trust")
    }

    func testBundledRulesLoadAndCompile() {
        let loaded = PipelineRules.load()
        XCTAssertGreaterThan(loaded.count, 40)
        for r in loaded {
            XCTAssertNotNil(try? NSRegularExpression(pattern: r.match), r.match)
            XCTAssertFalse(r.pipelines.isEmpty, r.match)
        }
    }

    func testGitChecksumMatchesGit() {
        // `printf hello | git hash-object --stdin`
        XCTAssertEqual(PipelineUpdater.blobSHA(Data("hello".utf8)), "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
    }

    func testMergeKeepsOrderAndContent() throws {
        let merged = PipelineUpdater.merge(["{\n  \"b\": {\"x\": 1}\n}", "{ \"a\": {\"y\": 2} }", "{}"])
        XCTAssertLessThan(merged.range(of: "\"b\"")!.lowerBound, merged.range(of: "\"a\"")!.lowerBound)
        let parsed = try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        XCTAssertEqual(Set(parsed?.keys.map { $0 } ?? []), ["a", "b"])
    }

    func testBrandedLog() {
        XCTAssertEqual(SatDumpRunner.branded("$ satdump legacy live x"), "$ engine live x")
        XCTAssertEqual(SatDumpRunner.branded("Starting SatDump v2"), "Starting engine v2")
    }
}

final class HostRankingTests: XCTestCase {
    private func host(_ id: String, iso: String, lat: Double, lon: Double, full: Bool = false) -> SpyHost {
        SpyHost(host: id, port: 1, device: "x", details: "", lat: lat, lon: lon, minHz: 1, maxHz: 2, maxSampleRate: 1, maxBandwidth: 1,
                clients: full ? 1 : 0, maxClients: 1, fullControl: true, iso: iso)
    }

    func testNearestFirstAcrossBorders() {
        let oulu = Station(name: "Oulu", lat: 65.01, lon: 25.47, iso: "fi")
        let hosts = [host("berlin", iso: "de", lat: 52.5, lon: 13.4), host("tampere", iso: "fi", lat: 61.5, lon: 23.8),
                     host("local", iso: "fi", lat: 65.1, lon: 25.5), host("lulea", iso: "se", lat: 65.6, lon: 22.2), host("usa", iso: "us", lat: 40, lon: -100)]
        let sorted = HostRanking.sort(hosts, near: oulu) { _ in .available }
        XCTAssertEqual(sorted.map(\.host), ["local", "lulea", "tampere", "berlin", "usa"], "a nearer foreign host beats one in the same country")
    }

    func testNearerUnavailableHostStaysAhead() {
        let place = Station(name: "X", lat: 50, lon: 10, iso: "de")
        let hosts = [host("fullNear", iso: "de", lat: 50.1, lon: 10), host("okFar", iso: "de", lat: 53, lon: 10), host("deadNearest", iso: "de", lat: 50.01, lon: 10)]
        let sorted = HostRanking.sort(hosts, near: place) {
            $0.host == "deadNearest" ? .dead : $0.host == "fullNear" ? .unavailable : .available
        }
        XCTAssertEqual(sorted.map(\.host), ["fullNear", "okFar", "deadNearest"], "by distance, with dead hosts last")
    }

    func testNoSearchKeepsStatusOrder() {
        let hosts = [host("a", iso: "de", lat: 1, lon: 1), host("b", iso: "fr", lat: 2, lon: 2)]
        XCTAssertEqual(HostRanking.sort(hosts, near: nil) { $0.host == "a" ? .dead : .available }.first?.host, "b")
    }
}

final class AGCTableTests: XCTestCase {
    func testOnlySourcesWithRealAGCAreListed() {
        for id in ["rtlsdr", "rtltcp", "airspy", "hydrasdr", "airspyhf", "sdrplay", "plutosdr", "bladerf", "aaronia"] {
            XCTAssertNotNil(SDRCatalog.agc[id], id)
        }
        // RFNM's plugin contains "lna_agc", but SatDump uses that key for its bandwidth.
        for id in ["spyserver", "websdr", "sdrpp_server", "net_source", "hackrf", "limesdr", "usrp", "mirisdr", "fobos", "rfnm"] {
            XCTAssertNil(SDRCatalog.agc[id], id)
        }
    }

    func testEverySourceExplainsItself() {
        for s in SDRCatalog.sources where SDRCatalog.agc[s.id] == nil {
            XCTAssertFalse(SDRCatalog.noAGCReason(s).isEmpty, s.id)
        }
    }

    func testArgumentsUseTheCatalogSources() {
        let known = Set(SDRCatalog.sources.map(\.id))
        for id in SDRCatalog.agc.keys { XCTAssertTrue(known.contains(id), id) }
    }
}

final class SavedFilesTests: XCTestCase {
    private func file(_ name: String, size: Int64, age: TimeInterval) -> ResultFile {
        let c = ResultClassifier.classify(name: name)
        return ResultFile(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: c.kind, title: c.title, size: size, modified: Date(timeIntervalSinceNow: -age))
    }

    func testListsWhatMattersNewestFirst() {
        let s = ResultSession(folder: URL(fileURLWithPath: "/tmp/a"), info: nil, title: "SAT", started: .now, ended: .now, files: [
            file("old.png", size: 100, age: 500), file("new.cs16", size: 100, age: 5), file("dataset.json", size: 96, age: 1),
            file("product.cbor", size: 400, age: 1), file("empty.cadu", size: 0, age: 1),
        ])
        XCTAssertEqual(SavedFiles.recent([s]).map(\.file.name), ["new.cs16", "old.png"])
        XCTAssertEqual(SavedFiles.recent([s], limit: 1).count, 1)
    }

    func testPassProgress() {
        let start = Date(timeIntervalSince1970: 1000)
        let pass = PassState.pass(PassInfo(aos: start, los: start.addingTimeInterval(100), maxElevation: 40, inProgress: true))
        XCTAssertEqual(SavedFiles.passFraction(started: start, pass: pass, now: start.addingTimeInterval(25)) ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(SavedFiles.passFraction(started: start, pass: pass, now: start.addingTimeInterval(500)), 1, "capped once the pass ends")
        XCTAssertNil(SavedFiles.passFraction(started: start, pass: .alwaysVisible), "no known end means the bar sweeps")
    }
}

final class HostLinkTests: XCTestCase {
    func testBarsFollowLatencyAndLoss() {
        XCTAssertEqual(HostLink(roundTripMs: 30, lost: 0).bars, 5)
        XCTAssertEqual(HostLink(roundTripMs: 100, lost: 0).bars, 4)
        XCTAssertEqual(HostLink(roundTripMs: 150, lost: 0).bars, 3)
        XCTAssertEqual(HostLink(roundTripMs: 300, lost: 0).bars, 2)
        XCTAssertEqual(HostLink(roundTripMs: 900, lost: 0).bars, 1)
        XCTAssertEqual(HostLink(roundTripMs: 30, lost: 2).bars, 3)
        XCTAssertEqual(HostLink(roundTripMs: 900, lost: 2).bars, 1)
        XCTAssertEqual(HostLink(roundTripMs: nil, lost: 3).bars, 0)
    }
}

@MainActor final class SpectrumFeedTests: XCTestCase {
    func testAxisAndWaterfall() {
        let f = SpectrumFeed()
        f.begin(frequency: 100e6, sampleRate: 2e6, mode: .listen)
        var v = [Float](repeating: -80, count: 1000)
        v[750] = -20
        f.update(v)
        f.update(v)
        XCTAssertEqual(f.peakHz ?? 0, 100.5e6, accuracy: 1)
        XCTAssertEqual(f.waterfall?.height, SpectrumFeed.rows)
        XCTAssertEqual(f.waterfall?.width, 1000)
        f.end()
        XCTAssertNil(f.mode)
        XCTAssertFalse(f.values.isEmpty, "the last spectrum stays readable")
    }

    func testPeaksIgnoreNoiseAndKeepAbsoluteFrequency() {
        var v = [Float](repeating: -80, count: 1024)
        v[300] = -40; v[700] = -60; v[50] = -78
        let p = SpectrumFeed.peaks(v, frequency: 100e6, sampleRate: 1.024e6, count: 5)
        XCTAssertEqual(p.count, 2, "the 2 dB bump isn't a station")
        XCTAssertEqual(p[0], 100e6 + (300.0 / 1024 - 0.5) * 1.024e6, accuracy: 1)
    }

    func testColourRampEnds() {
        XCTAssertLessThan(SpectrumFeed.color(0).2, 40)
        XCTAssertGreaterThan(SpectrumFeed.color(1).1, 240)
        XCTAssertEqual(SpectrumFeed.color(-5).0, SpectrumFeed.color(0).0)
    }
}

final class RadarRuleTests: XCTestCase {
    private func b(_ id: Int, _ el: Double, _ o: OrbitClass = .leo) -> RadarBlip { RadarBlip(id: id, azimuth: 0, elevation: el, orbit: o) }

    func testOnlyWhatIsAboveTheHorizonShows() {
        XCTAssertEqual(RadarTracker.passing([b(1, -0.1), b(2, 0), b(3, 80), b(4, 5)], filter: nil).map(\.id), [3, 4, 2])
    }

    func testFiltersApplyBeforeTheLimit() {
        // 100 high satellites the filter hides, and three low ones it allows: those three must show.
        let crowd = (0..<100).map { b($0, 60 + Double($0) * 0.1) } + [b(500, 5), b(501, 12), b(502, 8)]
        let shown = RadarTracker.passing(crowd, filter: nil) { $0 >= 500 }
        XCTAssertEqual(shown.map(\.id), [501, 502, 500])
    }

    func testCrossingIsFoundToTheSecond() {
        // Something that happens 137.4 s in, searched for inside a 60 s step.
        let t = RadarTracker.crossing(from: 120, to: 180) { $0 >= 137.4 }
        XCTAssertEqual(t, 137.4, accuracy: 1)
        XCTAssertGreaterThanOrEqual(t, 137.4, "never reported before it has happened")
    }

    func testStationaryObjectsAppearOnlyWhenChosen() {
        let list = [b(1, 50, .geo), b(2, 50, .deep), b(3, 50, .meo)]
        XCTAssertEqual(RadarTracker.passing(list, filter: nil).map(\.id), [3])
        XCTAssertEqual(RadarTracker.passing(list, filter: .geo).map(\.id), [1])
    }

    func testCrowdIsCappedAtTheHighest() {
        let many = (0..<500).map { b($0, 20 + Double($0) * 0.1) }
        let shown = RadarTracker.passing(many, filter: nil)
        XCTAssertEqual(shown.count, RadarTracker.maxShown)
        XCTAssertEqual(shown.first?.id, 499)
    }
}

final class TileTests: XCTestCase {
    func testParentsAndAddress() {
        XCTAssertEqual(TileKey(z: 14, x: 11722, y: 7695).parent, TileKey(z: 13, x: 5861, y: 3847))
        XCTAssertEqual(TileStore.url(TileKey(z: 8, x: 182, y: 120)).absoluteString,
                       "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/8/120/182.jpg")
    }
}

final class GroundPointTests: XCTestCase {
    func testMatchesTheGeneralCalculation() {
        let g = GroundPoint(lat: 12.97, lon: 77.57)
        for target in [SIMD3<Double>(1000, 6500, 2000), SIMD3<Double>(-3000, 4000, 4000), SIMD3<Double>(6778, 0, 0)] {
            let a = Astro.lookAngles(target: target, latDeg: 12.97, lonDeg: 77.57)
            let b = g.look(at: target)
            XCTAssertEqual(a.el, b.el, accuracy: 1e-9)
            XCTAssertEqual(a.az, b.az, accuracy: 1e-9)
        }
    }

    func testStraightUpAndOverTheHorizon() {
        let g = GroundPoint(lat: 0, lon: 0)
        XCTAssertGreaterThan(g.elevation(of: SIMD3(7000, 0, 0)), 89)
        XCTAssertLessThan(g.elevation(of: SIMD3(-7000, 0, 0)), 0)
    }
}

final class SignalTests: XCTestCase {
    func testCRCReferenceValue() {
        XCTAssertEqual(AX25.crc(Array("123456789".utf8)), 0x906E)
    }

    func testAddressEncoding() {
        let f = AX25.uiFrame(source: "W1AW-7", destination: "APZODK", path: ["ARISS"], info: ">hi")
        XCTAssertEqual(f[0], UInt8(ascii: "A") << 1)
        XCTAssertEqual(f[7], UInt8(ascii: "W") << 1)
        XCTAssertEqual(f[13] & 0x1E, 7 << 1)
        XCTAssertEqual(f[13] & 1, 0, "source is not the last address")
        XCTAssertEqual(f[20] & 1, 1, "the last digipeater closes the address field")
        XCTAssertEqual(f[21], 0x03)
        XCTAssertEqual(f[22], 0xF0)
    }

    func testBitStuffingNeverLeavesSixOnes() {
        let bits = AX25.bits(frame: [0xFF, 0xFF, 0xFF], preambleFlags: 0, trailingFlags: 0)
        var run = 0, longest = 0
        for b in bits { run = b ? run + 1 : 0; longest = max(longest, run) }
        XCTAssertEqual(longest, 5)
    }

    func testMorseTiming() {
        let t = AudioSignals.morseTiming("E T")
        XCTAssertEqual(t.map(\.on), [true, false, true])
        XCTAssertEqual(t.map(\.dits), [1, 7, 3])
        // PARIS is the standard word: 50 dits with its trailing word gap, so 43 without.
        XCTAssertEqual(AudioSignals.morseTiming("PARIS").reduce(0) { $0 + $1.dits }, 43)
    }

    func testCWLengthAndEdges() {
        let s = AudioSignals.cw(text: "E", wpm: 20)
        XCTAssertEqual(Double(s.count), 0.06 * AudioSignals.sampleRate, accuracy: 2)
        XCTAssertLessThan(abs(s[0]), 0.01)
        XCTAssertLessThan(abs(s[s.count - 1]), 0.01)
    }

    func testToneFrequencies() {
        // All ones means no NRZI transitions, so a steady 1200 Hz mark tone.
        let mark = AudioSignals.afsk(bits: Array(repeating: true, count: 1200))
        var crossings = 0
        for i in 1..<mark.count where (mark[i - 1] < 0) != (mark[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings) / 2, 1200, accuracy: 2)
    }
}

final class HostStatusTests: XCTestCase {
    private func host(clients: Int = 0, maxClients: Int = 2, full: Bool = true, offline: Bool = false, network: SpyHost.Network = .spyServer) -> SpyHost {
        SpyHost(network: network, listedOffline: offline, host: "h", port: 1, device: "d", details: "", lat: 0, lon: 0,
                minHz: 24e6, maxHz: 1800e6, maxSampleRate: 6e6, maxBandwidth: 6e6, clients: clients, maxClients: maxClients,
                fullControl: full, iso: "de")
    }

    func testEachStatus() {
        XCTAssertEqual(HostStatus.resolve(host(), health: .answering, frequency: 137e6), .available)
        XCTAssertEqual(HostStatus.resolve(host(), health: nil, frequency: 137e6), .checking)
        XCTAssertEqual(HostStatus.resolve(host(), health: .silent, frequency: 137e6), .dead)
        XCTAssertEqual(HostStatus.resolve(host(clients: 2), health: .answering, frequency: nil), .unavailable, "full")
        XCTAssertEqual(HostStatus.resolve(host(), health: .answering, frequency: 2400e6), .unavailable, "out of range")
        XCTAssertEqual(HostStatus.resolve(host(full: false), health: .answering, frequency: nil), .unavailable, "no retuning")
        XCTAssertEqual(HostStatus.resolve(host(offline: true), health: nil, frequency: nil), .dead, "directory says offline")
    }

    func testDeadBeatsFull() {
        XCTAssertEqual(HostStatus.resolve(host(clients: 2), health: .silent, frequency: nil), .dead)
    }

    func testOrder() {
        let order: [HostStatus] = [.dead, .available, .unavailable, .checking].sorted()
        XCTAssertEqual(order, [.available, .checking, .unavailable, .dead])
    }

    func testRestrictedRetuningOnlyAppliesToSpyServer() {
        XCTAssertEqual(HostStatus.resolve(host(full: false, network: .webSDR), health: .answering, frequency: nil), .available)
    }
}

final class RecordingHealthTests: XCTestCase {
    private let f = 137_900_000.0, rate = 1_250_000.0

    /// Log-power noise with some variance, as a single FFT frame looks.
    private func noise(_ n: Int = 1024, floor: Float = -60, sd: Float = 2.5, rolloff: Bool = true, seed: inout UInt64) -> [Float] {
        (0..<n).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let a = Float((seed >> 33) & 0xFFFF) / 65535, b = Float((seed >> 17) & 0xFFFF) / 65535
            let g = sqrt(-2 * log(max(a, 1e-6))) * cos(2 * .pi * b)
            var v = floor + g * sd
            if rolloff {
                let e = abs(Float(i) / Float(n) - 0.5) * 2
                if e > 0.85 { v -= (e - 0.85) * 60 }
            }
            return v
        }
    }

    private func frames(_ count: Int = 30, _ add: (inout [Float]) -> Void = { _ in }) -> [[Float]] {
        var seed: UInt64 = 42
        return (0..<count).map { _ in var v = noise(seed: &seed); add(&v); return v }
    }

    func testPlainNoiseIsNotASignal() {
        let r = SpectrumReading.analyse(frames: frames(), frequency: f, sampleRate: rate)!
        XCTAssertFalse(r.onFrequency)
        XCTAssertFalse(r.elsewhere)
        XCTAssertFalse(r.silent)
    }

    func testReceiverSpikeAtCentreIsIgnored() {
        let r = SpectrumReading.analyse(frames: frames { $0[512] += 25; $0[513] += 12; $0[511] += 12 }, frequency: f, sampleRate: rate)!
        XCTAssertFalse(r.onFrequency)
        XCTAssertFalse(r.elsewhere)
    }

    func testWideSignalNearCentreIsFound() {
        // About 100 kHz wide and 5 dB up, 30 kHz off centre.
        let r = SpectrumReading.analyse(frames: frames { v in for i in 496...600 { v[i] += 5 } }, frequency: f, sampleRate: rate)!
        XCTAssertTrue(r.onFrequency)
        XCTAssertGreaterThan(r.widthHz, 50_000)
        XCTAssertGreaterThanOrEqual(r.peakExcessDB, 4)
    }

    func testNarrowCarrierIsFound() {
        let r = SpectrumReading.analyse(frames: frames { $0[540] += 12 }, frequency: f, sampleRate: rate)!
        XCTAssertTrue(r.onFrequency)
    }

    func testSignalFarFromFrequencyIsFlaggedSeparately() {
        // 370 kHz off, which no Doppler shift could explain.
        let r = SpectrumReading.analyse(frames: frames { v in for i in 815...825 { v[i] += 8 } }, frequency: f, sampleRate: rate)!
        XCTAssertFalse(r.onFrequency)
        XCTAssertTrue(r.elsewhere)
        XCTAssertEqual(r.peakOffsetHz, 370_000, accuracy: 15_000)
    }

    func testAWeakerSignalOnFrequencyBeatsAStrongerOneElsewhere() {
        let r = SpectrumReading.analyse(frames: frames { v in
            for i in 815...825 { v[i] += 20 }
            for i in 530...545 { v[i] += 5 }
        }, frequency: f, sampleRate: rate)!
        XCTAssertTrue(r.onFrequency)
        XCTAssertLessThan(abs(r.peakOffsetHz), 60_000)
    }

    func testEmptySamplesAreCalledOut() {
        let flat = [[Float]](repeating: [Float](repeating: -290, count: 512), count: 10)
        XCTAssertTrue(SpectrumReading.analyse(frames: flat, frequency: f, sampleRate: rate)!.silent)
        let v = HealthVerdict.judge(reading: .init(floorDB: -290, peakExcessDB: 0, peakOffsetHz: 0, widthHz: 0, onFrequency: false, elsewhere: false, silent: true),
                                    mode: .record, framesLocked: false, elevation: 40, noiseSeconds: 0)
        XCTAssertEqual(v.level, .bad)
    }

    func testVerdicts() {
        var r = SpectrumReading.nothing
        func judge(_ m: CaptureMode = .record, locked: Bool = false, el: Double? = 40, noise: TimeInterval = 0) -> HealthLevel {
            HealthVerdict.judge(reading: r, mode: m, framesLocked: locked, elevation: el, noiseSeconds: noise).level
        }
        XCTAssertEqual(judge(noise: 5), .caution, "a pass can start weak")
        XCTAssertEqual(judge(noise: 30), .bad)
        XCTAssertEqual(judge(el: -5, noise: 1), .bad, "below the horizon needs no waiting")
        XCTAssertEqual(judge(locked: true), .good, "frames are proof")
        r.onFrequency = true
        XCTAssertEqual(judge(), .good)
        XCTAssertEqual(judge(el: -5), .caution, "it can't be this satellite below the horizon")
        XCTAssertEqual(judge(.listen), .caution, "a decoder that hasn't locked hasn't proved anything")
        r.onFrequency = false; r.elsewhere = true
        XCTAssertEqual(judge(), .caution)
        XCTAssertEqual(HealthVerdict.judge(reading: nil, mode: .record, framesLocked: false, elevation: 40, noiseSeconds: 0).level, .unknown)
    }

    func testMissingSamplesOutrankASignal() {
        var r = SpectrumReading.nothing
        r.onFrequency = true
        func judge(_ a: Double?) -> HealthVerdict { HealthVerdict.judge(reading: r, mode: .record, framesLocked: false, elevation: 40, noiseSeconds: 0, arrival: a) }
        XCTAssertEqual(judge(0.04).level, .bad)
        XCTAssertEqual(judge(0.04).title, "Losing samples")
        XCTAssertEqual(judge(0.5).level, .caution)
        XCTAssertEqual(judge(0.95).title, "Signal present")
        XCTAssertEqual(judge(nil).title, "Signal present")
        XCTAssertEqual(HealthVerdict.bytesPerSample("cs16"), 4)
        XCTAssertNil(HealthVerdict.bytesPerSample("ziq"))
    }

    @MainActor func testMonitorCountsNoiseThenRecovers() async {
        let m = HealthMonitor()
        m.begin(frequency: f, sampleRate: rate, mode: .record)
        var seed: UInt64 = 7
        for _ in 0..<8 { m.update(fft: noise(seed: &seed), framesLocked: false) }
        XCTAssertEqual(m.verdict.level, .caution)
        for _ in 0..<40 { var v = noise(seed: &seed); for i in 496...600 { v[i] += 8 }; m.update(fft: v, framesLocked: false) }
        XCTAssertEqual(m.verdict.title, "Signal present")
        XCTAssertEqual(m.noiseSeconds, 0)
        m.end()
        m.update(fft: noise(seed: &seed), framesLocked: false)
        XCTAssertEqual(m.verdict.title, "Signal present", "the last verdict stays once stopped")
    }
}

final class SignalRateTests: XCTestCase {
    private func host(_ top: Double) -> SpyHost {
        SpyHost(host: "h", port: 1, device: "d", details: "", lat: 0, lon: 0, minHz: 24e6, maxHz: 1800e6, maxSampleRate: top,
                maxBandwidth: top, clients: 0, maxClients: 2, fullControl: true, iso: "de")
    }

    func testMeteorFitsTheLowestRateTheSlowestHostDelivered() {
        let need = SignalRate.needed(symbolRate: 72_000, baud: nil, frequency: 137_900_000)
        XCTAssertEqual(need, 150_895, accuracy: 1)
        // Measured: this host managed 99% at this rate and 8 bits, and fell far behind above it.
        XCTAssertEqual(host(10_000_000).snappedRate(for: need), 156_250)
    }

    func testRateAlwaysHoldsTheSignal() {
        for (sym, f) in [(72_000.0, 137.9e6), (665_400, 1701.3e6), (2_661_600, 1701.3e6), (48_000, 145.8e6)] {
            let need = SignalRate.needed(symbolRate: sym, baud: nil, frequency: f)
            XCTAssertGreaterThan(need, sym * 1.6, "must fit the signal with its filter skirts")
            let got = host(20_000_000).snappedRate(for: need)
            XCTAssertGreaterThanOrEqual(got, need)
            XCTAssertLessThan(got, need * 2.01, "no more than one step above what's needed")
        }
    }

    func testWithoutASymbolRate() {
        XCTAssertEqual(SignalRate.needed(symbolRate: nil, baud: nil, frequency: 145.8e6), 50_000 + 7_290, accuracy: 1)
        XCTAssertEqual(SignalRate.needed(symbolRate: nil, baud: 9600, frequency: 435e6), 50_000 + 21_750, accuracy: 1)
        XCTAssertEqual(SignalRate.needed(symbolRate: nil, baud: 100_000, frequency: 435e6), 400_000 + 21_750, accuracy: 1)
    }

    func testAHostThatCantSampleFastEnoughGivesItsBest() {
        XCTAssertEqual(host(768_000).snappedRate(for: 6_000_000), 768_000)
    }

    func testTooSlowMakesAWorkingHostYellow() {
        XCTAssertEqual(HostStatus.resolve(host(10e6), health: .answering, frequency: nil, tooSlow: true), .unavailable)
        XCTAssertEqual(HostStatus.resolve(host(10e6), health: .answering, frequency: nil), .available)
        XCTAssertEqual(HostStatus.resolve(host(10e6), health: .silent, frequency: nil, tooSlow: true), .dead)
    }
}

final class StartProblemTests: XCTestCase {
    private func check(sat: String? = "SAT", enc: EncryptionInfo.State? = .no, engine: Bool = false, web: Bool = false, freq: Bool = true,
                       decoding: Bool = true, decoder: Bool = true, needsAddress: Bool = false, spy: Bool = true) -> StartProblem? {
        StartProblem.check(satellite: sat, encryption: enc, engineMissing: engine, browserOnly: web, hasFrequency: freq,
                           decoding: decoding, hasDecoder: decoder, needsAddress: needsAddress, isSpy: spy)
    }

    func testReady() { XCTAssertNil(check()) }
    func testEachReason() {
        XCTAssertTrue(check(sat: nil)!.message.contains("Lock"))
        XCTAssertTrue(check(engine: true)!.message.contains("engine"))
        XCTAssertTrue(check(web: true)!.message.contains("browser"))
        XCTAssertTrue(check(freq: false)!.message.contains("No public frequency"))
        XCTAssertTrue(check(needsAddress: true)!.message.contains("spy host"))
        XCTAssertTrue(check(needsAddress: true, spy: false)!.message.contains("address"))
    }
    func testEncryptionIsNamedWhenItIsTheReason() {
        XCTAssertTrue(check(enc: .yes, freq: false)!.message.contains("encrypted"))
        XCTAssertTrue(check(enc: .yes, decoder: false)!.message.contains("encrypted"))
        XCTAssertTrue(check(enc: .partly, decoder: false)!.message.contains("partly encrypted"))
        XCTAssertFalse(check(enc: .no, decoder: false)!.message.contains("encrypted"))
    }
    func testSaveToFileIsOfferedOnlyWhenItWouldWork() {
        XCTAssertTrue(check(decoder: false)!.canSaveInstead)
        XCTAssertFalse(check(decoder: false, needsAddress: true)!.canSaveInstead)
        XCTAssertNil(check(decoding: false, decoder: false), "saving to file needs no decoder")
    }
}

final class PlacesTests: XCTestCase {
    private let places = Places(places: [
        .init(lat: 53.48, lon: -2.24, name: "Manchester", state: "England"),
        .init(lat: 12.97, lon: 77.59, name: "Bengaluru", state: "Karnataka"),
        .init(lat: 64.5, lon: 179.9, name: "East", state: ""),
    ])

    func testNearestInRange() {
        XCTAssertEqual(places.nearest(lat: 53.455, lon: -2.394)?.name, "Manchester")
        XCTAssertEqual(places.nearest(lat: 13.2, lon: 77.2)?.state, "Karnataka")
    }
    func testNothingNearIsNil() { XCTAssertNil(places.nearest(lat: 0, lon: -30)) }
    func testAcrossTheDateLine() { XCTAssertEqual(places.nearest(lat: 64.5, lon: -179.9)?.name, "East") }

    func testHostNames() {
        var h = SpyHost(host: "h", port: 1, device: "d", details: "", lat: 0, lon: 0, minHz: 0, maxHz: 1, maxSampleRate: 1, maxBandwidth: 1,
                        clients: 0, maxClients: 1, fullControl: true, iso: "gb")
        XCTAssertEqual(h.shortName, "United Kingdom")
        h.city = "Manchester"; h.state = "England"
        XCTAssertEqual(h.shortName, "United Kingdom, England", "state wins over city")
        XCTAssertTrue(h.placeName.hasPrefix("Manchester, England, United Kingdom"))
        h.state = ""
        XCTAssertEqual(h.shortName, "United Kingdom, Manchester", "the city stands in for a missing state")
        var sg = SpyHost(host: "h", port: 1, device: "d", details: "", lat: 0, lon: 0, minHz: 0, maxHz: 1, maxSampleRate: 1, maxBandwidth: 1,
                         clients: 0, maxClients: 1, fullControl: true, iso: "sg")
        sg.city = "Singapore"; sg.state = "Singapore"
        XCTAssertEqual(sg.shortName, "Singapore", "a city-state isn't named twice")
    }

    private func host(_ id: String, lat: Double, lon: Double) -> SpyHost {
        SpyHost(host: id, port: 1, device: "d", details: "", lat: lat, lon: lon, minHz: 0, maxHz: 1, maxSampleRate: 1, maxBandwidth: 1,
                clients: 0, maxClients: 1, fullControl: true, iso: "de")
    }

    func testHostsAroundASpot() {
        let spot = Station(name: "x", lat: 50, lon: 10, iso: "de")
        // Roughly 111 km per degree of latitude.
        let near = (1...5).map { host("near\($0)", lat: 50 + Double($0) * 0.3, lon: 10) }
        let far = host("far", lat: 70, lon: 10)
        var r = HostRanking.around(near + [far], place: spot) { _ in .available }
        XCTAssertEqual(r.radiusKm, 300, "enough close by, so it stays small")
        XCTAssertEqual(r.hosts.map(\.host), ["near1", "near2", "near3", "near4", "near5"])

        // Dead hosts don't count towards enough, so the area widens, and they sort last.
        r = HostRanking.around(near + [far], place: spot) { $0.host == "near1" ? .dead : .available }
        XCTAssertEqual(r.radiusKm, 2500)
        XCTAssertEqual(r.hosts.last?.host, "near1")
        XCTAssertEqual(r.hosts.first?.host, "near2")

        // A few alive, none far: the widest area still shows them.
        r = HostRanking.around(Array(near.prefix(2)), place: spot) { _ in .available }
        XCTAssertEqual(r.radiusKm, 5000)
        XCTAssertEqual(r.hosts.count, 2)

        // Only dead hosts in reach: the closest living ones matter more.
        r = HostRanking.around(near + [host("o", lat: -50, lon: -170)], place: spot) { $0.host == "o" ? .available : .dead }
        XCTAssertNil(r.radiusKm)
        XCTAssertEqual(r.hosts.map(\.host), ["o"])

        // No published position: left out, wherever it claims to be.
        let nowhere = SpyHost(host: "n", port: 1, device: "d", details: "", lat: 50, lon: 10, minHz: 0, maxHz: 1, maxSampleRate: 1,
                              maxBandwidth: 1, clients: 0, maxClients: 1, fullControl: true, iso: "")
        XCTAssertFalse(HostRanking.around(near + [nowhere], place: spot) { _ in .available }.hosts.contains { $0.host == "n" })

        // Nothing in reach at all: the closest anywhere, rather than an empty list.
        let opposite = (1...7).map { host("o\($0)", lat: -50, lon: -170 + Double($0)) }
        r = HostRanking.around(opposite, place: spot) { _ in .available }
        XCTAssertNil(r.radiusKm)
        XCTAssertEqual(r.hosts.count, 5)
    }

    func testRegionNames() {
        XCTAssertEqual(SpyHost.shortName(country: "Germany", state: "Bavaria", city: "Munich"), "Germany, Bavaria")
        XCTAssertEqual(SpyHost.shortName(country: "Germany", state: "", city: "Munich"), "Germany, Munich")
        XCTAssertEqual(SpyHost.shortName(country: "Germany", state: "", city: ""), "Germany")
    }

    /// A straight overhead line of samples for a point at 0°, 0°: above the horizon only where listed.
    private func track(_ up: [Bool]) -> [HostPasses.Sample] {
        up.enumerated().map { i, isUp in
            // Earth's radius is about 6,378 km along +x at 0°, 0°, so +x beyond it is overhead and -x is below.
            HostPasses.Sample(jd: 2460000 + Double(i) / 1440, position: SIMD3(isUp ? 7000 : -7000, 0, 0))
        }
    }

    func testFirstPassOnATrack() throws {
        let ground = GroundPoint(lat: 0, lon: 0)
        XCTAssertNil(HostPasses.firstPass(on: track([false, false]), ground: ground), "never rises")

        let later = try XCTUnwrap(HostPasses.firstPass(on: track([false, true, true, false, true]), ground: ground))
        XCTAssertGreaterThan(later.aos, Date(timeIntervalSince1970: (2460000 - 2440587.5) * 86400), "rises after the start")
        XCTAssertLessThan(later.aos, try XCTUnwrap(later.los))
        XCTAssertEqual(later.maxElevation, 90, accuracy: 0.01)
        let duration = try XCTUnwrap(later.los).timeIntervalSince(later.aos)
        XCTAssertLessThan(duration, 180, "only the first pass")

        let up = try XCTUnwrap(HostPasses.firstPass(on: track([true, true]), ground: ground))
        XCTAssertNil(up.los, "still up when the window ends, like a geostationary satellite")
        XCTAssertEqual(up.aos, Date(timeIntervalSince1970: (2460000 - 2440587.5) * 86400))
    }

    func testWhoCanHearASatellite() {
        func h(_ id: String, maxHz: Double = 1) -> SpyHost {
            SpyHost(host: id, port: 1, device: "d", details: "", lat: 0, lon: 0, minHz: 0, maxHz: maxHz, maxSampleRate: 1, maxBandwidth: 1,
                    clients: 0, maxClients: 1, fullControl: true, iso: "de")
        }
        let now = Date()
        func pass(_ min: Double, height: Double = 10) -> HostArrival {
            HostArrival(aos: now.addingTimeInterval(min * 60), los: now.addingTimeInterval(min * 60 + 300), maxElevation: height)
        }
        let hosts = [h("later", maxHz: 200), h("soon", maxHz: 200), h("hfOnly", maxHz: 30), h("dead", maxHz: 200), h("neverOver", maxHz: 200), h("lowSame", maxHz: 200), h("highSame", maxHz: 200)]
        let arrivals = ["later:1": pass(60), "soon:1": pass(5), "hfOnly:1": pass(1), "dead:1": pass(1), "lowSame:1": pass(30, height: 5), "highSame:1": pass(30, height: 50)]
        let list = HostPasses.listing(hosts, arrivals: arrivals, frequency: 137) { $0.host == "dead" ? .dead : .available }
        XCTAssertEqual(list.map(\.host), ["soon", "highSame", "lowSame", "later"], "soonest first, leaving out what can't tune, is dead, or never sees it")
        XCTAssertEqual(HostPasses.listing(hosts, arrivals: arrivals, frequency: nil) { _ in .available }.first?.host, "dead",
                       "with no known frequency only the orbit decides")
    }

    func testArrivalInView() {
        let now = Date()
        XCTAssertTrue(HostArrival(aos: now.addingTimeInterval(-10), los: now.addingTimeInterval(10), maxElevation: 5).inView(at: now))
        XCTAssertFalse(HostArrival(aos: now.addingTimeInterval(10), los: now.addingTimeInterval(20), maxElevation: 5).inView(at: now))
        XCTAssertFalse(HostArrival(aos: now.addingTimeInterval(-20), los: now.addingTimeInterval(-10), maxElevation: 5).inView(at: now))
        XCTAssertTrue(HostArrival(aos: now.addingTimeInterval(-20), los: nil, maxElevation: 5).inView(at: now))
    }

    func testWavHeaderWhileStillBeingWritten() throws {
        // As the engine writes it: real format, with a data size that means nothing yet.
        var d = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVEfmt ".utf8)
        d += Data([16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0xBB, 0, 0, 0, 0x77, 1, 0, 2, 0, 16, 0])
        d += Data("data".utf8) + Data([0, 0, 0, 0])
        let f = try XCTUnwrap(WavFormat.parse(d))
        XCTAssertEqual(f, WavFormat(sampleRate: 48000, channels: 1, dataOffset: 44))

        var float = d
        float[20] = 3 // IEEE float
        XCTAssertNil(WavFormat.parse(float))
        XCTAssertNil(WavFormat.parse(Data("not audio at all".utf8)))
        XCTAssertNil(WavFormat.parse(d.prefix(20)), "the header isn't all there yet")
    }

    func testWavSamples() {
        let bytes = Data([0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x80])
        XCTAssertEqual(WavFormat.samples(bytes, channels: 1), [0.5, -0.5, 32767.0 / 32768, -1])
        XCTAssertEqual(WavFormat.samples(bytes, channels: 2), [0.5, 32767.0 / 32768], "the first channel only")
        XCTAssertEqual(WavFormat.samples(bytes.prefix(3), channels: 1), [0.5], "half a sample waits for the rest")
        XCTAssertEqual(WavFormat.samples(Data(), channels: 1), [])
    }

    func testLiveEdgeStaysOnAFrame() {
        let mono = WavFormat(sampleRate: 48000, channels: 1, dataOffset: 44)
        XCTAssertEqual(AudioMonitor.liveEdge(end: 20, format: mono), 44, "nothing written yet")
        XCTAssertEqual(AudioMonitor.liveEdge(end: 100, format: mono), 44, "less than the lead so far")
        let end = UInt64(44 + 48000 * 2 * 10 + 1)
        let edge = AudioMonitor.liveEdge(end: end, format: mono)
        XCTAssertEqual((edge - 44) % 2, 0)
        XCTAssertEqual(end - edge, UInt64(48000 * 0.3) * 2 + 1)
    }

    private func uplink(low: Double, high: Double, modes: [TxMode]) -> Uplink {
        Uplink(id: "u", description: "", lowHz: low, highHz: high, modeName: "", downlinkLowHz: 1, downlinkHighHz: 1, downlinkMode: "",
               inverted: false, ctcssHz: nil, modes: modes)
    }

    func testCommunicationKinds() {
        XCTAssertEqual(CommunicationKind.of(norad: 1, uplinks: []), [])
        XCTAssertEqual(CommunicationKind.of(norad: 1, uplinks: [uplink(low: 1, high: 1, modes: [.fmVoice])]), [.fmRepeater])
        XCTAssertEqual(CommunicationKind.of(norad: 1, uplinks: [uplink(low: 1, high: 2, modes: [.ssbVoice, .cw])]), [.linear])
        XCTAssertEqual(CommunicationKind.of(norad: 1, uplinks: [uplink(low: 1, high: 1, modes: [.cw])]), [.linear])
        XCTAssertEqual(CommunicationKind.of(norad: 1, uplinks: [uplink(low: 1, high: 1, modes: [.aprs, .packet1200])]), [.digital])
        XCTAssertEqual(CommunicationKind.of(norad: 1, uplinks: [uplink(low: 1, high: 1, modes: [.fmVoice, .aprs])]), [.fmRepeater, .digital])
        XCTAssertEqual(CommunicationKind.of(norad: CommunicationKind.issNorad, uplinks: [uplink(low: 1, high: 1, modes: [.fmVoice])]), [.fmRepeater, .iss])
        XCTAssertEqual(CommunicationKind.of(norad: CommunicationKind.issNorad, uplinks: []), [], "no usable uplink, nothing to talk through")
    }

    func testFindingSatellitesNeverWidensTransmitting() {
        func tx(_ description: String, service: String, uplink: Double = 145_850_000) -> Transmitter {
            Transmitter(description: description, downlinkHz: 436_795_000, mode: "FM", active: true, baud: nil,
                        uplinkLowHz: uplink, uplinkMode: "FM", service: service, kind: "Transceiver")
        }
        // Like SO-50: an amateur repeater with no service recorded.
        let blank = tx("Mode V/U FM Voice CTCSS 67.0 Hz", service: "Unknown")
        XCTAssertNil(UplinkPolicy.make(blank), "not enough to transmit on")
        XCTAssertEqual(UplinkPolicy.make(blank, unknownServiceOK: true)?.modes, [.fmVoice], "but enough to find it")
        XCTAssertNotNil(UplinkPolicy.make(tx("Mode V/U FM Voice", service: "Amateur")))

        XCTAssertNil(UplinkPolicy.make(tx("Mode V/U FM Voice", service: "Space Operation"), unknownServiceOK: true), "someone else's service")
        XCTAssertNil(UplinkPolicy.make(tx("Mode V/V FM (crew R1)", service: "Unknown", uplink: 145_200_000), unknownServiceOK: true), "the ISS crew's frequency")
        XCTAssertNil(UplinkPolicy.make(tx("Telecommand FM", service: "Unknown"), unknownServiceOK: true), "commanding a satellite")
    }

    func testCommunicationFilter() {
        var f = SatelliteFilter()
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .no, hasFrequency: true))
        f.communication = .fmRepeater
        XCTAssertEqual(f.activeCount, 1)
        XCTAssertTrue(f.isActive)
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, communication: [.fmRepeater, .digital]))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, communication: [.linear]))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true))
    }

    func testAMSATNames() {
        XCTAssertEqual(AMSATAPI.baseName("SO-50_[FM]"), "SO-50")
        XCTAssertEqual(AMSATAPI.baseName("TEVEL2-4_[FM]"), "TEVEL2-4")
        XCTAssertEqual(AMSATAPI.baseName("Out_of_the_Box_[Music]"), "Out_of_the_Box")
        XCTAssertTrue(AMSATAPI.candidates(name: "SAUDISAT 1C (SO-50)", norad: 27607).contains("SO-50"))
        XCTAssertTrue(AMSATAPI.candidates(name: "RS-44 & BREEZE-KM R/B", norad: 44909).contains("RS-44"))
        XCTAssertTrue(AMSATAPI.candidates(name: "LUCA (RS90S)", norad: 1).isSuperset(of: ["LUCA", "RS90S"]))
        XCTAssertTrue(AMSATAPI.candidates(name: "RADFXSAT (FOX-1B)", norad: 43017).contains("AO-91"))
        XCTAssertTrue(AMSATAPI.candidates(name: "ISS (ZARYA)", norad: 25544).contains("ISS"))
        XCTAssertFalse(AMSATAPI.candidates(name: "ISS (UNITY)", norad: 25575).contains("ISS"), "another piece of the station has no radio")
    }

    func testAMSATSummaryAndModes() throws {
        let catalog = #"{"data":[{"id":1,"name":"ISS_[FM]","display_name":"ISS [FM]","website":"x"},{"id":2,"name":"ISS_[SSTV]","display_name":"ISS [SSTV]"},{"id":3,"name":"ISS_[UHF_Digi]","display_name":"ISS [UHF Digi]"},{"id":4,"name":"SO-50_[FM]","display_name":"SO-50 [FM]"}],"meta":{"count":4}}"#
        let summary = #"{"data":[{"name":"ISS_[FM]","satellite_display_name":"ISS [FM]","report":"Heard","report_count":7,"latest_reported_time":"2026-11-04T15:22:02Z"},{"name":"ISS_[FM]","satellite_display_name":"ISS [FM]","report":"Not Heard","report_count":6,"latest_reported_time":"2026-11-05T03:40:00Z"},{"name":"ISS_[UHF_Digi]","report":"Heard","report_count":3,"latest_reported_time":"2026-11-04T13:45:00Z"},{"name":"SO-50_[FM]","report":"Heard","report_count":11,"latest_reported_time":"2026-11-05T02:54:00Z"}],"meta":{"hours":24,"count":4}}"#
        let d = JSONDecoder()
        let c = try d.decode(AMSATAPI.List<AMSATAPI.CatalogEntry>.self, from: Data(catalog.utf8)).data
        let s = try d.decode(AMSATAPI.List<AMSATAPI.SummaryRow>.self, from: Data(summary.utf8)).data
        let modes = AMSATAPI.modes(for: "ISS (ZARYA)", norad: 25544, catalog: c, summary: s)
        XCTAssertEqual(modes.map(\.name), ["ISS_[FM]", "ISS_[UHF_Digi]", "ISS_[SSTV]"], "most recent first, unreported last")
        XCTAssertEqual(modes[0].counts, ["Heard": 7, "Not Heard": 6])
        XCTAssertEqual(modes[0].total, 13)
        XCTAssertEqual(modes[0].latestReport, "Not Heard", "the newest report is the one that says how it is now")
        XCTAssertEqual(modes[0].latest, AMSATAPI.date("2026-11-05T03:40:00Z"))
        XCTAssertNil(modes[2].latest)
        XCTAssertTrue(AMSATAPI.modes(for: "STARLINK-1007", norad: 44713, catalog: c, summary: s).isEmpty)
    }

    func testAMSATReportDecodesWithoutAGrid() throws {
        let json = #"{"data":[{"id":9,"name":"SO-50_[FM]","satellite_display_name":"SO-50 [FM]","reported_time":"2026-11-05T02:54:00Z","callsign":"W1AW","report":"Heard","grid_square":null}]}"#
        let r = try JSONDecoder().decode(AMSATAPI.List<AMSATAPI.Report>.self, from: Data(json.utf8)).data[0]
        XCTAssertEqual(r.callsign, "W1AW")
        XCTAssertNil(r.grid_square)
        XCTAssertEqual(r.date, AMSATAPI.date("2026-11-05T02:54:00Z"))
    }

    func testAMSATSubmissionIsBuiltOnlyFromWhatWasConfirmed() throws {
        let at = try XCTUnwrap(AMSATAPI.date("2026-11-05T08:30:00Z"))
        let r = try XCTUnwrap(AMSATAPI.submission(name: "SO-50_[FM]", observation: .notHeard, callsign: "W1AW-7", grid: "FN31", at: at))
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://status.amsat.org/api/v1/reports.php")
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), AMSATAPI.userAgent)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["name": "SO-50_[FM]", "report": "Not Heard", "callsign": "W1AW", "grid_square": "FN31", "reported_at": "2026-11-05T08:30:00Z"],
                       "the operator's callsign without a station's SSID, at the time observed")
        let noGrid = try XCTUnwrap(AMSATAPI.submission(name: "SO-50_[FM]", observation: .heard, callsign: "W1AW", grid: nil, at: at))
        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(noGrid.httpBody)) as? [String: String])
        XCTAssertNil(bare["grid_square"], "a public host's location is never sent as the operator's")
    }

    func testAMSATQueryEncoding() {
        XCTAssertEqual(AMSATAPI.query("SO-50_[FM]"), "SO-50_%5BFM%5D")
        XCTAssertEqual(AMSATAPI.query("AO-7_[U/v]"), "AO-7_%5BU%2Fv%5D")
    }

    func testAMSATPollingKeepsToTheirLimit() {
        XCTAssertGreaterThanOrEqual(AMSATAPI.pollSeconds, 300)
        XCTAssertGreaterThan(AMSATAPI.backoffSeconds, AMSATAPI.pollSeconds)
    }

    private func downlink(_ description: String, mode: String, hz: Double, active: Bool = true, baud: Double? = nil) -> Transmitter {
        Transmitter(description: description, downlinkHz: hz, mode: mode, active: active, baud: baud)
    }

    func testRecognisingPictureSignals() {
        // Real SatNOGS listings.
        XCTAssertEqual(MediaSignal.kind(of: downlink("Mode U - SSTV - Robot-36", mode: "SSTV", hz: 437_550_000)), .sstv)
        XCTAssertEqual(MediaSignal.kind(of: downlink("Mode U SSTV", mode: "FM", hz: 437_405_000)), .sstv, "the description says so even if the mode doesn't")
        XCTAssertEqual(MediaSignal.kind(of: downlink("SSDV (PL 88.5Hz)", mode: "AFSK", hz: 435_880_000)), .ssdv)
        XCTAssertEqual(MediaSignal.kind(of: downlink("Mode S - HamTV DVB-S", mode: "DVB-S2", hz: 2_395_000_000)), .datv)
        XCTAssertEqual(MediaSignal.kind(of: downlink("Mode X - DVB-S2", mode: "DVB-S2", hz: 10_475_000_000)), .datv)
        XCTAssertNil(MediaSignal.kind(of: downlink("Imagery Downlink", mode: "DVB-S2", hz: 8_150_000_000)), "a commercial data link isn't video")
        XCTAssertNil(MediaSignal.kind(of: downlink("DVB-S2 8PSK 2/3", mode: "None", hz: 8_240_000_000)))
        XCTAssertNil(MediaSignal.kind(of: downlink("Mode U SSTV", mode: "SSTV", hz: 437_000_000, active: false)), "off the air")
        XCTAssertNil(MediaSignal.kind(of: downlink("Mode V/U FM Voice", mode: "FM", hz: 436_795_000)))
    }

    func testPictureFormats() {
        XCTAssertEqual(MediaSignal.format(in: "Mode U - SSTV - Robot-36"), "Robot-36")
        XCTAssertEqual(MediaSignal.format(in: "SSTV - Robot 72"), "Robot 72")
        XCTAssertEqual(MediaSignal.format(in: "Mode S - SSTV - PD120"), "PD120")
        XCTAssertEqual(MediaSignal.format(in: "Mode V - SSTV - Martin M1 SSTV"), "Martin M1")
        XCTAssertNil(MediaSignal.format(in: "Mode U - SSTV"))
    }

    func testPictureSignalsAreListedOncePerFrequency() {
        let list = MediaSignal.signals(in: [
            downlink("Mode S - SSTV - PD120", mode: "SSTV", hz: 2_405_500_000),
            downlink("Mode S - SSTV - PD120", mode: "SSTV", hz: 2_405_500_000),
            downlink("Mode U - SSDV", mode: "BPSK", hz: 436_210_000, baud: 9600),
            downlink("Beacon", mode: "CW", hz: 436_000_000),
        ])
        XCTAssertEqual(list.map(\.title), ["SSTV PD120", "SSDV"])
    }

    func testPictureSignalSampleRates() {
        let sstv = MediaSignal(kind: .sstv, hz: 1, format: nil, baud: nil)
        XCTAssertNil(sstv.neededSampleRate, "the audio decoder sets its own")
        XCTAssertEqual(MediaSignal(kind: .ssdv, hz: 1, format: nil, baud: 9600).neededSampleRate, 250_000)
        XCTAssertEqual(MediaSignal(kind: .ssdv, hz: 1, format: nil, baud: 100_000).neededSampleRate, 1_000_000)
        XCTAssertEqual(MediaSignal(kind: .datv, hz: 1, format: nil, baud: nil).neededSampleRate, 2_500_000)
        XCTAssertEqual(MediaSignal(kind: .datv, hz: 1, format: nil, baud: 2_000_000).neededSampleRate, 5_000_000)
    }

    func testAMSATPictureModes() {
        XCTAssertEqual(MediaKind.fromAMSATMode("ISS_[SSTV]"), .sstv)
        XCTAssertEqual(MediaKind.fromAMSATMode("AO-123_[SSDV]"), .ssdv)
        XCTAssertEqual(MediaKind.fromAMSATMode("ISS_[DATV]"), .datv)
        XCTAssertEqual(MediaKind.fromAMSATMode("CO-128_[DVB-S2]"), .datv)
        XCTAssertNil(MediaKind.fromAMSATMode("SO-50_[FM]"))
        XCTAssertNil(MediaKind.fromAMSATMode("BALKAN-1_[Music]"))
    }

    func testMediaFilter() {
        var f = SatelliteFilter()
        f.media = .sstv
        XCTAssertEqual(f.activeCount, 1)
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, media: [.sstv, .datv]))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, media: [.ssdv]))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true))
    }

    func testParticleSizeGrowsAsResultsShrink() {
        let total = 16875
        XCTAssertEqual(ParticleSize.growth(shown: total, total: total), 0)
        XCTAssertEqual(ParticleSize.growth(shown: 1, total: total), 1)
        XCTAssertEqual(ParticleSize.growth(shown: 0, total: total), 1)
        XCTAssertEqual(ParticleSize.growth(shown: 0, total: 0), 0)
        let sizes = [total, 5000, 1000, 100, 10, 1].map { ParticleSize.points(base: 3, growth: ParticleSize.growth(shown: $0, total: total)) }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(sizes.first, 3)
        XCTAssertEqual(sizes.last, ParticleSize.iconPoints, "the largest dot is the locked icon's size")
        XCTAssertLessThan(sizes[1], 6, "a broad filter barely changes anything")
    }
}

final class ScanTests: XCTestCase {
    private let res = 488.0

    /// A pass: the range rate runs from approaching to receding as the satellite goes over.
    private func rr(_ t: Double) -> Double { -6 + 12 * t / 120 }

    private func track(_ f: (Double) -> Double, every: Double = 10, until: Double = 120) -> [ScanCandidate] {
        var tr = ScanTracker(resolutionHz: res)
        var t = 0.0
        while t <= until {
            tr.add(ScanDetection(hz: f(t), excessDB: 12, widthHz: 1000), rangeRate: rr(t), time: t)
            t += every
        }
        return tr.candidates
    }

    func testSignalFollowingTheOrbitMatches() {
        let f0 = 437_000_000.0
        let c = track { f0 * (1 - self.rr($0) / Doppler.c) }
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].verdict, .dopplerMatch)
        XCTAssertEqual(c[0].restHz, f0, accuracy: 200, "reports what the satellite transmits, not what arrived")
    }

    func testAFewSightingsAreNotEnoughForAMatch() {
        let f0 = 437_000_000.0
        let c = track({ f0 * (1 - self.rr($0) / Doppler.c) }, every: 30, until: 90)
        XCTAssertEqual(c.first?.sightings, 4)
        XCTAssertEqual(c.first?.verdict, .undetermined)
    }

    func testGroundTransmitterIsFixed() {
        let c = track { _ in 437_250_000 }
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].verdict, .fixed)
    }

    func testAnotherSatelliteDriftsTheOtherWay() {
        let c = track { 437_000_000 * (1 + self.rr($0) / Doppler.c) }
        XCTAssertNotEqual(c.first?.verdict, .dopplerMatch)
    }

    func testNoVerdictWhenTheSatelliteBarelyDrifts() {
        var tr = ScanTracker(resolutionHz: res)
        for t in stride(from: 0.0, through: 60, by: 10) {
            tr.add(ScanDetection(hz: 137_500_000, excessDB: 10, widthHz: 1000), rangeRate: 0.001, time: t)
        }
        XCTAssertEqual(tr.candidates.first?.verdict, .undetermined, "a geostationary satellite can't be told from the ground this way")
    }

    func testOneSightingIsNotACandidate() {
        var tr = ScanTracker(resolutionHz: res)
        tr.add(ScanDetection(hz: 137_500_000, excessDB: 20, widthHz: 1000), rangeRate: 1, time: 0)
        XCTAssertTrue(tr.candidates.isEmpty)
    }

    func testMatchesRankFirstAndTracksStaySeparate() {
        var tr = ScanTracker(resolutionHz: res)
        for t in stride(from: 0.0, through: 120, by: 10) {
            tr.add(ScanDetection(hz: 435_600_000, excessDB: 30, widthHz: 1000), rangeRate: rr(t), time: t)
            tr.add(ScanDetection(hz: 437_000_000 * (1 - rr(t) / Doppler.c), excessDB: 8, widthHz: 1000), rangeRate: rr(t), time: t)
        }
        let c = tr.candidates
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].verdict, .dopplerMatch, "a weak match beats a strong ground signal")
        XCTAssertEqual(c[1].verdict, .fixed)
    }

    func testPiecesOfOneWideSignalBecomeOne() {
        var tr = ScanTracker(resolutionHz: res)
        for t in stride(from: 0.0, through: 60, by: 10) {
            for piece in stride(from: 0.0, through: 150_000, by: 12_000) {
                tr.add(ScanDetection(hz: 98_000_000 + piece, excessDB: 12, widthHz: 3000), rangeRate: 1, time: t)
            }
            tr.add(ScanDetection(hz: 98_400_000, excessDB: 12, widthHz: 3000), rangeRate: 1, time: t)
        }
        XCTAssertEqual(tr.candidates.count, 2, "one wide station, and one separate signal")
        XCTAssertGreaterThan(tr.candidates.map(\.widthHz).max()!, 100_000)
    }

    func testPeaksSkipCentreAndEdgesAndLandOnTheRightFrequency() {
        var v = [Float](repeating: 50, count: 4096)
        v[2048] = 90 // the receiver's centre spike
        v[10] = 90 // filter edge
        v[3000] = 70
        let d = ScanPeaks.find(spectrum: v, centerHz: 100_000_000, spanHz: 2_000_000)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].hz, 100_000_000 + (3000.5 - 2048) / 4096 * 2_000_000, accuracy: 1)
        XCTAssertEqual(d[0].excessDB, 20)
    }

    func testPlanCoversEveryBandWithinTheHost() {
        let band = ScanBand(name: "t", lowHz: 435e6, highHz: 438e6)
        let p = ScanWindow.plan(bands: [band], maxBandwidth: 8e6, minHz: 24e6, maxHz: 1800e6)
        XCTAssertEqual(p.stage, 2)
        XCTAssertEqual(p.windows.first?.spanHz, 2e6)
        XCTAssertLessThanOrEqual(p.windows.first!.lowHz, 435e6)
        XCTAssertGreaterThanOrEqual(p.windows.last!.highHz, 438e6)
        for (a, b) in zip(p.windows, p.windows.dropFirst()) { XCTAssertLessThan(b.lowHz, a.highHz, "no gaps") }
        XCTAssertTrue(ScanWindow.plan(bands: [band], maxBandwidth: 8e6, minHz: 24e6, maxHz: 300e6).windows.isEmpty)
    }

    func testEveryCategoryHasBands() {
        for c in SatCategory.allCases { XCTAssertFalse(ScanBand.likely(for: c).isEmpty, c.rawValue) }
    }
}

final class SatelliteFilterTests: XCTestCase {
    func testDefaultKeepsEverything() {
        let f = SatelliteFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .unknown, hasFrequency: false))
    }

    func testYear() {
        let f = SatelliteFilter(year: 2024)
        XCTAssertTrue(f.matches(launchYear: 2024, encryption: .no, hasFrequency: true))
        XCTAssertFalse(f.matches(launchYear: 2023, encryption: .no, hasFrequency: true))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true))
    }

    func testEncryption() {
        let yes = SatelliteFilter(encryption: .yes), no = SatelliteFilter(encryption: .no)
        XCTAssertTrue(yes.matches(launchYear: nil, encryption: .yes, hasFrequency: false))
        XCTAssertTrue(yes.matches(launchYear: nil, encryption: .partly, hasFrequency: false))
        XCTAssertFalse(yes.matches(launchYear: nil, encryption: .no, hasFrequency: false))
        XCTAssertTrue(no.matches(launchYear: nil, encryption: .no, hasFrequency: false))
        XCTAssertFalse(no.matches(launchYear: nil, encryption: .partly, hasFrequency: false))
        XCTAssertFalse(yes.matches(launchYear: nil, encryption: .unknown, hasFrequency: false), "unknown only shows under Any")
        XCTAssertFalse(no.matches(launchYear: nil, encryption: .unknown, hasFrequency: false))
    }

    func testCountry() {
        let f = SatelliteFilter(country: "India")
        XCTAssertTrue(f.isActive)
        XCTAssertTrue(f.matches(launchYear: 2020, encryption: .no, hasFrequency: true, country: "India"))
        XCTAssertFalse(f.matches(launchYear: 2020, encryption: .no, hasFrequency: true, country: "Japan"))
        XCTAssertFalse(f.matches(launchYear: 2020, encryption: .no, hasFrequency: true))
        let both = SatelliteFilter(year: 2024, country: "India")
        XCTAssertFalse(both.matches(launchYear: 2023, encryption: .no, hasFrequency: true, country: "India"))
    }

    func testCountryNamesReadNaturally() {
        XCTAssertEqual(OwnerCodes.displayName(for: "PRC"), "China")
        XCTAssertEqual(OwnerCodes.displayName(for: "UK"), "United Kingdom")
        XCTAssertEqual(OwnerCodes.iso(for: "KWT"), "kw")
    }

    func testFrequencyAndCombination() {
        let f = SatelliteFilter(year: 2020, frequency: .no)
        XCTAssertTrue(f.matches(launchYear: 2020, encryption: .no, hasFrequency: false))
        XCTAssertFalse(f.matches(launchYear: 2020, encryption: .no, hasFrequency: true))
        XCTAssertFalse(f.matches(launchYear: 2021, encryption: .no, hasFrequency: false))
    }
}

import SceneKit

final class GLBLoaderTests: XCTestCase {
    /// A one-triangle binary glTF, built by hand.
    private func glb(positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [UInt16] = [0, 1, 2], json extra: [String: Any] = [:]) -> Data {
        var bin = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let posLength = bin.count
        bin.append(indices.withUnsafeBufferPointer { Data(buffer: $0) })
        while bin.count % 4 != 0 { bin.append(0) }
        var json: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [["name": "keep", "mesh": 0, "translation": [1, 2, 3]]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]]]],
            "materials": [["pbrMetallicRoughness": ["baseColorFactor": [1, 0, 0, 1], "metallicFactor": 0.25, "roughnessFactor": 0.75]]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": positions.count / 3, "type": "VEC3"],
                          ["bufferView": 1, "componentType": 5123, "count": indices.count, "type": "SCALAR"]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": posLength],
                            ["buffer": 0, "byteOffset": posLength, "byteLength": indices.count * 2]],
        ]
        json.merge(extra) { _, new in new }
        var j = try! JSONSerialization.data(withJSONObject: json)
        while j.count % 4 != 0 { j.append(0x20) }
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        var out = Data("glTF".utf8) + u32(2) + u32(12 + 8 + j.count + 8 + bin.count)
        out += u32(j.count) + Data("JSON".utf8) + j
        out += u32(bin.count) + Data([0x42, 0x49, 0x4E, 0]) + bin
        return out
    }

    private func firstGeometry(_ n: SCNNode) -> SCNGeometry? {
        var g: SCNGeometry?
        n.enumerateHierarchy { c, stop in if let x = c.geometry { g = x; stop.pointee = true } }
        return g
    }

    func testReadsGeometryTransformAndMaterial() throws {
        let root = try GLBLoader.load(glb())
        let g = try XCTUnwrap(firstGeometry(root))
        XCTAssertEqual(g.elements.first?.primitiveCount, 1)
        XCTAssertEqual(g.sources(for: .vertex).first?.vectorCount, 3)
        XCTAssertEqual(g.sources(for: .normal).first?.vectorCount, 3, "normals are worked out when a file has none")
        XCTAssertEqual(root.childNodes.first?.position.y, 2)
        XCTAssertEqual(g.firstMaterial?.lightingModel, .physicallyBased)
        XCTAssertEqual(g.firstMaterial?.metalness.contents as? Double, 0.25)
        XCTAssertEqual(g.firstMaterial?.roughness.contents as? Double, 0.75)
    }

    func testRejectsGarbageAndTruncation() {
        XCTAssertThrowsError(try GLBLoader.load(Data()))
        XCTAssertThrowsError(try GLBLoader.load(Data("not a model at all, sorry......".utf8)))
        let good = glb()
        XCTAssertThrowsError(try GLBLoader.load(good.prefix(30)))
    }

    func testIndexOutsideTheMeshIsDropped() throws {
        XCTAssertNil(firstGeometry(try GLBLoader.load(glb(indices: [0, 1, 9]))))
    }

    func testAccessorPastTheBufferIsDropped() throws {
        let lying: [[String: Any]] = [["bufferView": 0, "componentType": 5126, "count": 9999, "type": "VEC3"],
                                      ["bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"]]
        XCTAssertNil(firstGeometry(try GLBLoader.load(glb(json: ["accessors": lying]))))
    }

    func testNodeLoopsEnd() throws {
        let loop: [[String: Any]] = [["mesh": 0, "children": [0]]]
        XCTAssertNotNil(firstGeometry(try GLBLoader.load(glb(json: ["nodes": loop]))))
    }
}

final class ModelCatalogTests: XCTestCase {
    private func choice(_ name: String, _ kind: SatelliteModel.Kind = .generic) -> ModelChoice { ModelCatalog.choice(forName: name, kind: kind) }

    func testNamedSpacecraftGetTheirOwnModel() {
        for (name, fragment) in [("ISS (ZARYA)", "ISS"), ("HST", "Hubble"), ("AQUA", "Aqua"), ("TERRA", "Terra"), ("CXO", "Chandra"),
                                 ("GOES 16", "Geostationary"), ("EWS-G2 (GOES 15)", "Geostationary"), ("TDRS 7", "TDRS"), ("SUOMI NPP", "Suomi")] {
            XCTAssertTrue(choice(name).path.contains(fragment), name)
            XCTAssertEqual(choice(name).match, .exact, name)
        }
    }

    func testNamesThatOnlyLookAlikeDoNotMatch() {
        for name in ["TERRASAR-X", "SKYTERRA 1", "SUOMI-100", "SWISSCUBE", "ELARASAT MMS-1"] {
            XCTAssertEqual(choice(name).match, .standIn, name)
        }
    }

    func testRelativesAreLabelledAsRelatives() {
        XCTAssertEqual(choice("NOAA 20 (JPSS-1)").match, .family)
        XCTAssertEqual(choice("LANDSAT 9").match, .family)
        XCTAssertTrue(choice("LANDSAT 9").caption.contains("family"))
    }

    func testClassesGetLabelledStandIns() {
        XCTAssertEqual(choice("INTELSAT 39", .comsat).match, .standIn)
        XCTAssertTrue(choice("INTELSAT 39", .comsat).caption.hasPrefix("Stand-in"))
        XCTAssertEqual(choice("FLOCK 4X-1", .weather).title, "MiRaTa CubeSat", "a shoebox imager isn't a big platform")
    }

    func testStarlinkAndTiangongUseTheirOwnModels() {
        XCTAssertEqual(choice("STARLINK-3005", .flatPanel).match, .exact)
        XCTAssertEqual(choice("STARLINK-3005", .flatPanel).bundled, "starlink.glb")
        XCTAssertEqual(choice("CSS (TIANHE)", .station).bundled, "tiangong.glb")
    }

    func testEverythingElseGetsALabelledStandInRatherThanAShape() {
        for (n, k) in [("ONEWEB-0100", SatelliteModel.Kind.flatPanel), ("NAVSTAR 86", .navigation), ("USA 245", .recon), ("OBJECT A", .generic), ("NUSTAR", .observatory)] {
            XCTAssertEqual(choice(n, k).match, .standIn, n)
            XCTAssertTrue(choice(n, k).caption.hasPrefix("Stand-in"), n)
        }
    }

    func testCommunityModelsCreditTheirAuthors() throws {
        XCTAssertTrue(choice("STARLINK-1", .flatPanel).caption.contains("Malacodart"))
        XCTAssertTrue(choice("OBJECT A").caption.contains("DjalalxJay"))
        XCTAssertTrue(choice("CSS (WENTIAN)", .station).caption.contains("w29572227"))
    }

    func testEveryLinkIsPinnedAndEscaped() throws {
        for rule in ModelCatalog.rules where rule.choice.bundled == nil {
            let url = try XCTUnwrap(rule.choice.url)
            XCTAssertTrue(url.absoluteString.contains(ModelChoice.commit))
            XCTAssertTrue(url.absoluteString.hasSuffix(".glb"))
            XCTAssertFalse(url.absoluteString.contains(" "))
        }
    }
}

final class LocationLinkTests: XCTestCase {
    private func host(_ name: String, lat: Double, lon: Double) -> SpyHost {
        SpyHost(host: name, port: 1, device: "d", details: "", lat: lat, lon: lon, minHz: 24e6, maxHz: 1800e6, maxSampleRate: 6e6, maxBandwidth: 6e6,
                clients: 0, maxClients: 2, fullControl: true, iso: "de")
    }

    func testSearchFindsTheNearestWorkingHostOnly() {
        let near = host("near", lat: 51, lon: 0), far = host("far", lat: -30, lon: 100), dead = host("dead", lat: 51.1, lon: 0.1)
        let place = Station(name: "London", lat: 51.5, lon: 0, iso: "gb")
        XCTAssertEqual(HostRanking.nearestWorking([far, near, dead], to: place) { $0.host == "dead" ? .dead : .available }?.host, "near")
        XCTAssertNil(HostRanking.nearestWorking([dead], to: place) { _ in .dead })
    }
}

private struct SSTVEncoder {
    let rate: Double
    var out: [Float] = []
    var phase = 0.0
    var drift = 1.0
    var toneOffset = 0.0

    init(rate: Double = 48000) { self.rate = rate }

    mutating func tone(_ hz: Double, ms: Double) {
        let n = Int((ms / 1000 * rate * drift + fraction).rounded(.down))
        fraction = ms / 1000 * rate * drift + fraction - Double(n)
        for _ in 0..<n {
            phase += 2 * .pi * (hz + toneOffset) / rate
            out.append(Float(sin(phase)) * 0.7)
        }
    }
    var fraction = 0.0

    mutating func vis(_ code: Int) {
        tone(1900, ms: 300); tone(1200, ms: 10); tone(1900, ms: 300); tone(1200, ms: 30)
        var parity = 0
        for bit in 0..<7 {
            let one = code >> bit & 1 == 1
            if one { parity += 1 }
            tone(one ? 1100 : 1300, ms: 30)
        }
        tone(parity % 2 == 1 ? 1100 : 1300, ms: 30)
        tone(1200, ms: 30)
    }

    mutating func scan(_ values: (Int) -> Double, width: Int, ms: Double) {
        for x in 0..<width { tone(1500 + values(x) / 255 * 800, ms: ms / Double(width)) }
    }

    // A test card: colour blocks left to right, changing down the picture.
    static func card(x: Int, y: Int, width: Int, height: Int) -> (r: Double, g: Double, b: Double) {
        let blocks: [(Double, Double, Double)] = [(230, 40, 40), (40, 210, 60), (50, 60, 230), (235, 235, 60), (240, 240, 240), (20, 20, 20)]
        let column = min(blocks.count - 1, x * blocks.count / width)
        let (r, g, b) = blocks[(column + (y * 2 / height) * 3) % blocks.count]
        return (r, g, b)
    }

    static func ycc(_ c: (r: Double, g: Double, b: Double)) -> (y: Double, cr: Double, cb: Double) {
        let y = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return (y, (c.r - y) / 1.402 + 128, (c.b - y) / 1.772 + 128)
    }

    mutating func martin(width: Int = 320, height: Int = 256, scan ms: Double) {
        for y in 0..<height {
            tone(1200, ms: 4.862); tone(1500, ms: 0.572)
            scan({ Self.card(x: $0, y: y, width: width, height: height).g }, width: width, ms: ms); tone(1500, ms: 0.572)
            scan({ Self.card(x: $0, y: y, width: width, height: height).b }, width: width, ms: ms); tone(1500, ms: 0.572)
            scan({ Self.card(x: $0, y: y, width: width, height: height).r }, width: width, ms: ms); tone(1500, ms: 0.572)
        }
    }

    mutating func scottie(width: Int = 320, height: Int = 256, scan ms: Double) {
        tone(1200, ms: 9)
        for y in 0..<height {
            tone(1500, ms: 1.5)
            scan({ Self.card(x: $0, y: y, width: width, height: height).g }, width: width, ms: ms); tone(1500, ms: 1.5)
            scan({ Self.card(x: $0, y: y, width: width, height: height).b }, width: width, ms: ms)
            tone(1200, ms: 9); tone(1500, ms: 1.5)
            scan({ Self.card(x: $0, y: y, width: width, height: height).r }, width: width, ms: ms)
        }
    }

    mutating func pd(width: Int, height: Int, scan ms: Double, rows: Int? = nil) {
        for y in stride(from: 0, to: rows ?? height, by: 2) {
            tone(1200, ms: 20); tone(1500, ms: 2.08)
            let line0 = (0..<width).map { Self.ycc(Self.card(x: $0, y: y, width: width, height: height)) }
            let line1 = (0..<width).map { Self.ycc(Self.card(x: $0, y: y + 1, width: width, height: height)) }
            scan({ line0[$0].y }, width: width, ms: ms)
            scan({ (line0[$0].cr + line1[$0].cr) / 2 }, width: width, ms: ms)
            scan({ (line0[$0].cb + line1[$0].cb) / 2 }, width: width, ms: ms)
            scan({ line1[$0].y }, width: width, ms: ms)
        }
    }

    mutating func robot36(width: Int = 320, height: Int = 240, rows: Int? = nil) {
        for y in 0..<(rows ?? height) {
            tone(1200, ms: 9); tone(1500, ms: 3)
            let line = (0..<width).map { Self.ycc(Self.card(x: $0, y: y, width: width, height: height)) }
            scan({ line[$0].y }, width: width, ms: 88)
            tone(y % 2 == 0 ? 1500 : 2300, ms: 4.5); tone(1900, ms: 1.5)
            scan({ y % 2 == 0 ? line[$0].cr : line[$0].cb }, width: width, ms: 44)
        }
    }

    mutating func robot72(width: Int = 320, height: Int = 240) {
        for y in 0..<height {
            tone(1200, ms: 9); tone(1500, ms: 3)
            let line = (0..<width).map { Self.ycc(Self.card(x: $0, y: y, width: width, height: height)) }
            scan({ line[$0].y }, width: width, ms: 138)
            tone(1500, ms: 4.5); tone(1900, ms: 1.5)
            scan({ line[$0].cr }, width: width, ms: 69)
            tone(2300, ms: 4.5); tone(1500, ms: 1.5)
            scan({ line[$0].cb }, width: width, ms: 69)
        }
    }
}

final class SSTVTests: XCTestCase {
    private func decode(_ audio: [Float], rate: Double = 48000) -> [SSTVPicture] {
        let decoder = SSTVDecoder(sampleRate: rate)
        var pictures: [SSTVPicture] = []
        decoder.onFinished = { pictures.append($0) }
        // In pieces, the way it arrives from the file.
        var at = 0
        while at < audio.count {
            let end = min(audio.count, at + 6000)
            decoder.feed(Array(audio[at..<end]))
            at = end
        }
        decoder.finish()
        return pictures
    }

    /// Average colour error against the test card, away from the edges between blocks.
    private func error(_ p: SSTVPicture, rows: Range<Int>? = nil) -> Double {
        var total = 0.0, count = 0
        let w = p.mode.width, h = p.mode.height
        for y in stride(from: (rows ?? 0..<h).lowerBound + 4, to: (rows ?? 0..<h).upperBound - 4, by: 7) {
            if abs(y * 2 / h - (y + 6) * 2 / h) > 0 || abs(y * 2 / h - (y - 6) * 2 / h) > 0 { continue }
            for block in 0..<6 {
                let x = w * block / 6 + w / 12
                let want = SSTVEncoder.card(x: x, y: y, width: w, height: h)
                let got = p.pixel(x: x, y: y)
                total += abs(Double(got.r) - want.r) + abs(Double(got.g) - want.g) + abs(Double(got.b) - want.b)
                count += 3
            }
        }
        return total / Double(max(count, 1))
    }

    private func check(_ name: String, vis: Int, draw: (inout SSTVEncoder) -> Void, tolerance: Double = 12,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        var e = SSTVEncoder()
        e.vis(vis)
        draw(&e)
        e.tone(1900, ms: 200)
        let pictures = decode(e.out)
        XCTAssertEqual(pictures.count, 1, name, file: file, line: line)
        let p = try XCTUnwrap(pictures.first, file: file, line: line)
        XCTAssertEqual(p.mode.name, name, file: file, line: line)
        XCTAssertFalse(p.joinedPartway, file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.rows, p.mode.height - 2, name, file: file, line: line)
        XCTAssertLessThan(error(p), tolerance, name, file: file, line: line)
    }

    func testRobot36() throws { try check("Robot 36", vis: 8, draw: { $0.robot36() }, tolerance: 25) }
    func testRobot72() throws { try check("Robot 72", vis: 12, draw: { $0.robot72() }) }
    func testMartinM1() throws { try check("Martin M1", vis: 44, draw: { $0.martin(scan: 146.432) }) }
    func testMartinM2() throws { try check("Martin M2", vis: 40, draw: { $0.martin(scan: 73.216) }) }
    func testScottieS1() throws { try check("Scottie S1", vis: 60, draw: { $0.scottie(scan: 138.24) }) }
    func testScottieS2() throws { try check("Scottie S2", vis: 56, draw: { $0.scottie(scan: 88.064) }) }
    func testPD120() throws { try check("PD120", vis: 95, draw: { $0.pd(width: 640, height: 496, scan: 121.6) }) }
    func testPD90() throws { try check("PD90", vis: 99, draw: { $0.pd(width: 320, height: 256, scan: 170.24) }) }

    func testFrameTimesMatchPublishedFigures() {
        let want: [String: Double] = ["Robot 36": 150, "Robot 72": 300, "Martin M1": 446.446, "Martin M2": 226.798, "Scottie S1": 428.22,
                                      "Scottie S2": 277.692, "Scottie DX": 1050.3, "PD50": 388.16, "PD90": 703.04, "PD120": 508.48,
                                      "PD160": 804.416, "PD180": 754.24, "PD240": 1000, "PD290": 937.28]
        XCTAssertEqual(SSTVMode.all.count, want.count)
        for m in SSTVMode.all { XCTAssertEqual(m.frameMs, want[m.name] ?? -1, accuracy: 0.01, m.name) }
    }

    func testOffTuneSignalKeepsItsColours() throws {
        var e = SSTVEncoder()
        e.toneOffset = 180 // Doppler left over after correction, or a little off frequency.
        e.vis(44)
        e.martin(scan: 146.432)
        let p = try XCTUnwrap(decode(e.out).first)
        XCTAssertEqual(p.mode.name, "Martin M1")
        XCTAssertLessThan(error(p), 15)
    }

    func testClockDriftDoesNotSmearThePicture() throws {
        var e = SSTVEncoder()
        e.vis(44)
        e.drift = 1.0005 // 5 parts in 10,000: about 25 samples over the width of a picture at this rate if uncorrected.
        e.martin(scan: 146.432)
        let p = try XCTUnwrap(decode(e.out).first)
        XCTAssertGreaterThanOrEqual(p.rows, 250)
        XCTAssertLessThan(error(p), 25)
    }

    func testNoisySignalStillDecodes() throws {
        var e = SSTVEncoder()
        e.vis(60)
        e.scottie(scan: 138.24)
        var random = SystemRandomNumberGenerator()
        let noisy = e.out.map { $0 + Float.random(in: -0.35...0.35, using: &random) }
        let p = try XCTUnwrap(decode(noisy).first)
        XCTAssertEqual(p.mode.name, "Scottie S1")
        XCTAssertLessThan(error(p), 30)
    }

    func testJoiningPartwayFromSyncPulses() throws {
        var e = SSTVEncoder()
        e.pd(width: 640, height: 496, scan: 121.6) // No header at all.
        let p = try XCTUnwrap(decode(e.out).first)
        XCTAssertEqual(p.mode.name, "PD120")
        XCTAssertTrue(p.joinedPartway)
        XCTAssertGreaterThan(p.rows, 400)
    }

    func testSignalLostKeepsWhatArrived() throws {
        var e = SSTVEncoder()
        e.vis(8)
        e.robot36(rows: 100)
        var random = SystemRandomNumberGenerator()
        // The satellite goes over the horizon, leaving noise.
        let audio = e.out + (0..<(48000 * 6)).map { _ in Float.random(in: -0.7...0.7, using: &random) }
        let pictures = decode(audio)
        XCTAssertEqual(pictures.count, 1)
        let p = try XCTUnwrap(pictures.first)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(Double(p.rows), 100, accuracy: 3)
    }

    func testNoiseAndVoiceAreNotPictures() {
        var random = SystemRandomNumberGenerator()
        let noise = (0..<(48000 * 60)).map { _ in Float.random(in: -0.7...0.7, using: &random) }
        XCTAssertTrue(decode(noise).isEmpty, "a minute of noise")
        var tones = SSTVEncoder()
        for i in 0..<200 { tones.tone(600 + Double(i % 17) * 110, ms: 120) }
        XCTAssertTrue(decode(tones.out).isEmpty, "shifting tones like a voice or a beacon")
    }

    func testTwoPicturesInARow() throws {
        var e = SSTVEncoder()
        e.vis(8); e.robot36()
        e.tone(1900, ms: 400)
        e.vis(44); e.martin(scan: 146.432)
        let pictures = decode(e.out)
        XCTAssertEqual(pictures.map(\.mode.name), ["Robot 36", "Martin M1"])
    }

    func testOtherAudioRates() throws {
        var e = SSTVEncoder(rate: 12500)
        e.vis(44)
        e.martin(scan: 146.432)
        let p = try XCTUnwrap(decode(e.out, rate: 12500).first)
        XCTAssertEqual(p.mode.name, "Martin M1")
        XCTAssertLessThan(error(p), 20)
    }
}

final class PacketTests: XCTestCase {
    private func decode(_ audio: [Float], rate: Double = AudioSignals.sampleRate) -> [AX25Frame] {
        let d = PacketDecoder(sampleRate: rate)
        var out: [AX25Frame] = []
        var at = 0
        while at < audio.count {
            let end = min(audio.count, at + 7000)
            out += d.feed(Array(audio[at..<end]))
            at = end
        }
        return out
    }

    private var silence: [Float] { [Float](repeating: 0, count: 4800) }

    func testAFSKRoundTrip() throws {
        let audio = silence + AudioSignals.aprs(source: "N0CALL-7", path: ["ARISS"], text: "Hello from orbit") + silence
        let frames = decode(audio)
        XCTAssertEqual(frames.count, 1, "several slicers, but one report")
        let f = try XCTUnwrap(frames.first)
        XCTAssertEqual(f.source, "N0CALL-7")
        XCTAssertEqual(f.destination, "APZODK")
        XCTAssertEqual(f.path, ["ARISS"])
        XCTAssertEqual(f.infoText, ">Hello from orbit")
    }

    func testG3RUHRoundTrip() throws {
        let audio = silence + AudioSignals.packet9600(source: "W1AW", path: [], text: "Fast packet") + silence
        let f = try XCTUnwrap(decode(audio).first)
        XCTAssertEqual(f.source, "W1AW")
        XCTAssertEqual(f.infoText, "Fast packet")
        XCTAssertEqual(try XCTUnwrap(decode(audio.map { -$0 }).first).infoText, "Fast packet", "either way up")
    }

    func testAFSKSurvivesNoiseAndTilt() throws {
        var random = SystemRandomNumberGenerator()
        let clean = AudioSignals.packet1200(source: "W1AW", path: [], text: "Through noise")
        // Radios lean towards one tone, which a first-order filter does here, as de-emphasis would.
        var held: Float = 0
        let tilted = clean.map { x -> Float in held += (x - held) * 0.25; return held * 2 }
        let noisy = tilted.map { $0 + Float.random(in: -0.25...0.25, using: &random) }
        XCTAssertEqual(try XCTUnwrap(decode(silence + noisy + silence).first).infoText, "Through noise")
    }

    func testAFSKAtALowerRate() throws {
        // Every 4th sample is 12 kHz, as an audio file could be.
        let audio = AudioSignals.packet1200(source: "W1AW", path: [], text: "Low rate")
        let thin = stride(from: 0, to: audio.count, by: 4).map { audio[$0] }
        XCTAssertEqual(try XCTUnwrap(decode(thin, rate: 12000).first).infoText, "Low rate")
    }

    func testNoiseProducesNoFrames() {
        var random = SystemRandomNumberGenerator()
        XCTAssertTrue(decode((0..<(48000 * 30)).map { _ in Float.random(in: -0.7...0.7, using: &random) }).isEmpty)
    }

    func testCorruptFrameIsRejected() {
        var frame = AX25.uiFrame(source: "W1AW", destination: "APZODK", path: [], info: ">test")
        XCTAssertNotNil(AX25Frame.parse(frame))
        frame[16] ^= 0x10
        XCTAssertNil(AX25Frame.parse(frame))
    }

    private func report(_ info: String, destination: String = "APRS") throws -> APRSReport {
        let frame = AX25.uiFrame(source: "W1AW-9", destination: destination, path: [], info: info)
        return try XCTUnwrap(APRSReport.parse(try XCTUnwrap(AX25Frame.parse(frame))))
    }

    func testAPRSPositions() throws {
        var r = try report("!4903.50N/07201.75W-Test")
        XCTAssertEqual(r.kind, .position)
        XCTAssertEqual(r.latitude ?? 0, 49.0583, accuracy: 0.001)
        XCTAssertEqual(r.longitude ?? 0, -72.0292, accuracy: 0.001)
        XCTAssertEqual(r.text, "Test")
        r = try report("/092345z4903.50N/07201.75W>Timestamped")
        XCTAssertEqual(r.latitude ?? 0, 49.0583, accuracy: 0.001)
        XCTAssertEqual(r.text, "Timestamped")
        r = try report("=3345.12S/15112.34E-South east")
        XCTAssertLessThan(r.latitude ?? 0, 0)
        XCTAssertGreaterThan(r.longitude ?? 0, 0)
        // The worked example in the APRS specification.
        r = try report("!/5L!!<*e7>7P[")
        XCTAssertEqual(r.latitude ?? 0, 49.5, accuracy: 0.001)
        XCTAssertEqual(r.longitude ?? 0, -72.75, accuracy: 0.001)
    }

    func testBlurredPositionsDecodeToTheMiddle() throws {
        let r = try report("=49  .  N/072  .  W-Vague")
        XCTAssertEqual(r.latitude ?? 0, 49 + 55.55 / 60, accuracy: 0.01)
        XCTAssertLessThan(r.longitude ?? 0, -72)
    }

    func testMicE() throws {
        // Latitude 33 25.64 N in the destination, whose last letters also say west and add 100 to the longitude.
        let info: [UInt8] = [0x60, 12 + 28, 7 + 28, 74 + 28, 0x20, 0x20, 0x20, 0x3E, 0x2F] + Array("Tracker".utf8)
        let f = AX25Frame(destination: "S32UVT", source: "W1AW", path: [], info: info)
        let r = try XCTUnwrap(APRSReport.parse(f))
        XCTAssertEqual(r.latitude ?? 0, 33 + 25.64 / 60, accuracy: 0.001)
        XCTAssertEqual(r.longitude ?? 0, -(112 + 7.74 / 60), accuracy: 0.001)
        XCTAssertEqual(r.text, "Tracker")
    }

    func testAPRSOtherKinds() throws {
        var r = try report(">On the air")
        XCTAssertEqual(r.kind, .status)
        XCTAssertEqual(r.text, "On the air")
        r = try report(":N0CALL   :Hello there{01")
        XCTAssertEqual(r.kind, .message)
        XCTAssertEqual(r.addressee, "N0CALL")
        XCTAssertEqual(r.text, "Hello there{01")
        r = try report("T#005,199,000,255,073,123,01101001")
        XCTAssertEqual(r.kind, .telemetry)
        r = try report(";LEADER   *092345z4903.50N/07201.75W>Object")
        XCTAssertEqual(r.kind, .object)
        XCTAssertEqual(r.addressee, "LEADER")
        XCTAssertEqual(r.latitude ?? 0, 49.0583, accuracy: 0.001)
        let plain = try XCTUnwrap(AX25Frame.parse(AX25.uiFrame(source: "W1AW", destination: "CQ", path: [], info: "plain text")))
        XCTAssertNil(APRSReport.parse(plain), "ordinary packet isn't APRS")
    }

    func testPositionBeaconFormat() {
        XCTAssertEqual(APRSPosition.info(lat: 49.05833, lon: -72.02917, precision: .exact, comment: "Hi"), "=4903.50N/07201.75W-Hi")
        XCTAssertEqual(APRSPosition.info(lat: 49.05833, lon: -72.02917, precision: .about2km, comment: ""), "=4903.  N/07201.  W-")
        XCTAssertEqual(APRSPosition.info(lat: -33.5, lon: 151.25, precision: .about20km, comment: ""), "=333 .  S/15115.  E-".replacingOccurrences(of: "15115", with: "1511 "))
        XCTAssertEqual(APRSPosition.angle(10.99999, degreeDigits: 2, positive: "N", negative: "S", blanks: 0), "1100.00N", "rounding carries into the degrees")
    }

    func testPositionBeaconRoundTrip() throws {
        for precision in APRSPosition.Precision.allCases {
            let info = APRSPosition.info(lat: 1.3521, lon: 103.8198, precision: precision, comment: "Vessel")
            let audio = silence + AudioSignals.aprsPacket(source: "9V1XY-7", path: ["ARISS"], info: info) + silence
            let f = try XCTUnwrap(decode(audio).first, precision.rawValue)
            let r = try XCTUnwrap(APRSReport.parse(f), precision.rawValue)
            XCTAssertEqual(r.kind, .position)
            XCTAssertEqual(r.text, "Vessel")
            let tolerance = precision == .exact ? 0.001 : precision == .about2km ? 0.02 : 0.2
            XCTAssertEqual(r.latitude ?? 0, 1.3521, accuracy: tolerance, precision.rawValue)
            XCTAssertEqual(r.longitude ?? 0, 103.8198, accuracy: tolerance, precision.rawValue)
        }
    }

    func testWhichDataDownlinksCanBeDecodedFromAudio() {
        func tx(_ description: String, _ mode: String) -> Transmitter {
            Transmitter(description: description, downlinkHz: 437e6, mode: mode, active: true, baud: 9600)
        }
        XCTAssertTrue(PipelineCatalog.isAX25Data(tx("Telemetry", "FSK AX.25 G3RUH")))
        XCTAssertTrue(PipelineCatalog.isAX25Data(tx("9k6 AX.25 digipeater", "GMSK")))
        XCTAssertFalse(PipelineCatalog.isAX25Data(tx("Telemetry", "FSK AX.100 Mode 5")))
        XCTAssertFalse(PipelineCatalog.isAX25Data(tx("Telemetry", "FSK")), "unknown framing")
        XCTAssertFalse(PipelineCatalog.isAX25Data(tx("AX.25 over BPSK", "BPSK")), "needs a different demodulator")
    }

    func testPositionNeedsYourOwnLocation() {
        XCTAssertNotNil(TxSignal.problem(mode: .aprsPosition, message: "", callsign: "W1AW"))
        XCTAssertNil(TxSignal.problem(mode: .aprsPosition, message: "=4903.50N/07201.75W-", callsign: "W1AW"))
        XCTAssertNil(TxSignal.render(mode: .aprsPosition, message: "", callsign: "W1AW", path: [], usb: false))
        XCTAssertNotNil(TxSignal.render(mode: .aprsPosition, message: "=4903.50N/07201.75W-", callsign: "W1AW", path: [], usb: false))
    }
}

final class SignalFormatTests: XCTestCase {
    private func tx(_ description: String, _ mode: String) -> Transmitter {
        Transmitter(description: description, downlinkHz: 437e6, mode: mode, active: true, baud: nil)
    }

    func testListedFormats() {
        let cases: [(String, String, SignalFormat)] = [
            ("Mode V/U FM Voice", "FM", .fmVoice), ("Mode U/V Linear", "USB", .ssbVoice), ("Beacon", "CW", .cw),
            ("Mode U SSTV", "FM", .sstv), ("SSDV (PL 88.5Hz)", "AFSK", .ssdv), ("Mode X - DVB-S2", "DVB-S2", .dvb),
            ("Mode V APRS", "AFSK", .aprs), ("Telemetry", "AFSK", .packet), ("Voice", "DSTAR", .digitalVoice),
            ("Telemetry", "FSK AX.25 G3RUH", .fsk), ("Telemetry", "GFSK", .fsk), ("Science", "BPSK", .psk), ("Downlink", "QPSK", .psk),
            ("Beacon", "LoRa", .lora), ("Weather", "LRPT", .weatherImage),
        ]
        for (description, mode, want) in cases { XCTAssertEqual(SignalFormat.listed(tx(description, mode)), want, "\(description), \(mode)") }
        XCTAssertNil(SignalFormat.listed(tx("Something", "UNKNOWN")))
    }

    private func sound(_ audio: [Float]) -> AudioFormatDetector.Sound? {
        var d = AudioFormatDetector(sampleRate: 48000)
        d.feed(audio)
        return d.sound
    }

    private func repeated(_ audio: [Float], seconds: Double) -> [Float] {
        var out: [Float] = []
        while Double(out.count) < seconds * 48000 { out += audio }
        return Array(out.prefix(Int(seconds * 48000)))
    }

    /// Morse at about 12 words a minute, as an audio tone.
    private func morse(tone: Double?) -> [Float] {
        var out: [Float] = []
        var phase = 0.0
        var random = SystemRandomNumberGenerator()
        func unit(_ on: Bool, _ units: Int) {
            for _ in 0..<(units * 4800) {
                phase += 2 * .pi * (tone ?? 0) / 48000
                let key: Float = on ? 1 : 0
                let carrier = tone == nil ? Float(0.6) : Float(sin(phase)) * 0.6
                out.append(key * carrier + Float.random(in: -0.01...0.01, using: &random))
            }
        }
        for _ in 0..<9 {
            for dash in [true, false, true, true, false] { unit(true, dash ? 3 : 1); unit(false, 1) }
            unit(false, 3)
        }
        return Array(out.prefix(48000 * 6))
    }

    func testRecognisesMorse() {
        XCTAssertEqual(sound(morse(tone: 700)), .cw, "as a tone")
        XCTAssertEqual(sound(morse(tone: nil)), .cw, "as a keyed level, as AM gives")
    }

    func testRecognisesPacketTones() {
        let bits = (0..<8000).map { _ in Bool.random() }
        XCTAssertEqual(sound(AudioSignals.afsk(bits: bits)), .afsk)
    }

    func testRecognisesSSTVTones() {
        var e = SSTVEncoder()
        e.martin(scan: 146.432)
        XCTAssertEqual(sound(Array(e.out.prefix(48000 * 6))), .sstv)
    }

    func testRecognisesVoice() {
        // Vowel-like harmonics of a moving pitch, rising and falling with syllables.
        var out: [Float] = []
        var phase = 0.0
        var random = SystemRandomNumberGenerator()
        for i in 0..<(48000 * 6) {
            let t = Double(i) / 48000
            let pitch = 130 + 30 * sin(2 * .pi * 0.7 * t)
            phase += 2 * .pi * pitch / 48000
            let syllable = max(0, sin(2 * .pi * 3.5 * t))
            var v = 0.0
            for h in 1...14 {
                let f = Double(h) * pitch
                let formant = exp(-pow((f - 600) / 350, 2)) + 0.6 * exp(-pow((f - 1500) / 450, 2))
                v += sin(phase * Double(h)) * formant
            }
            out.append(Float(v * syllable * 0.3) + Float.random(in: -0.002...0.002, using: &random))
        }
        XCTAssertEqual(sound(out), .voice)
    }

    func testNoiseAndSilenceSoundLikeNothing() {
        var random = SystemRandomNumberGenerator()
        XCTAssertNil(sound((0..<(48000 * 6)).map { _ in Float.random(in: -0.7...0.7, using: &random) }), "FM noise")
        XCTAssertNil(sound([Float](repeating: 0, count: 48000 * 6)), "silence")
        XCTAssertNil(sound([Float](repeating: 0.2, count: 100)), "too little to judge")
        let steady = (0..<(48000 * 6)).map { Float(sin(2 * .pi * 1000 * Double($0) / 48000)) * 0.5 }
        XCTAssertNotEqual(sound(steady), .cw, "a steady tone isn't keyed")
    }

    func testBinaryPacketsShowAsHex() throws {
        let f = AX25Frame(destination: "CQ", source: "W1AW", path: [], info: [0x4A, 0x0F, 0x2C])
        XCTAssertTrue(f.isBinary)
        XCTAssertEqual(f.hexText, "4A 0F 2C")
        XCTAssertFalse(AX25Frame(destination: "CQ", source: "W1AW", path: [], info: Array("hello\r".utf8)).isBinary)
    }
}

final class RadioFinderTests: XCTestCase {
    func testOnlyUSBSerialPortsAreEverAsked() {
        let ports = RadioFinder.candidatePorts(in: ["cu.Bluetooth-Incoming-Port", "cu.debug-console", "tty.usbserial-1", "cu.usbserial-1420",
                                                    "cu.usbmodem14201", "cu.SLAB_USBtoUART", "cu.wchusbserial10", "cu.AirPods"])
        XCTAssertEqual(ports, ["/dev/cu.SLAB_USBtoUART", "/dev/cu.usbmodem14201", "/dev/cu.usbserial-1420", "/dev/cu.wchusbserial10"])
    }

    func testIcomReply() {
        XCTAssertEqual(RadioFinder.parseIcom([0xFE, 0xFE, 0xE0, 0xA2, 0x19, 0x00, 0xA2, 0xFD]), "IC-9700")
        let echoed: [UInt8] = [0xFE, 0xFE, 0x00, 0xE0, 0x19, 0x00, 0xFD, 0xFE, 0xFE, 0xE0, 0x94, 0x19, 0x00, 0x94, 0xFD]
        XCTAssertEqual(RadioFinder.parseIcom(echoed), "IC-7300", "after the echo some radios send")
        XCTAssertEqual(RadioFinder.parseIcom([0xFE, 0xFE, 0xE0, 0x10, 0x19, 0x00, 0x10, 0xFD]), "Icom", "an Icom we don't have a name for")
        XCTAssertNil(RadioFinder.parseIcom([0xFE, 0xFE, 0x00, 0xE0, 0x19, 0x00, 0xFD]), "only the echo")
        XCTAssertNil(RadioFinder.parseIcom([1, 2, 3]))
        XCTAssertNil(RadioFinder.parseIcom([]))
    }

    func testIDReply() {
        XCTAssertEqual(RadioFinder.parseID(Array("ID0670;".utf8)), "FT-991")
        XCTAssertEqual(RadioFinder.parseID(Array("ID019;".utf8)), "TS-2000")
        XCTAssertNil(RadioFinder.parseID(Array("ID9999;".utf8)))
        XCTAssertNil(RadioFinder.parseID(Array("?;".utf8)))
    }

    func testHamlibLookup() {
        let list = """
         Rig #  Mfg                    Model                   Version         Status      Macro
          3081  Icom                   IC-9700                 20250107.1      Stable      RIG_MODEL_IC9700
          1035  Yaesu                  FT-991                  20241221.0      Stable      RIG_MODEL_FT991
        """
        XCTAssertEqual(RadioFinder.hamlibModel(named: "IC-9700", in: list), 3081)
        XCTAssertEqual(RadioFinder.hamlibModel(named: "FT-991", in: list), 1035)
        XCTAssertNil(RadioFinder.hamlibModel(named: "IC-7300", in: list))
    }

    /// A pretend radio on a real serial-style device, answering the way each family does.
    private func withPretendRadio(reply: @escaping ([UInt8]) -> [UInt8]?, run: (String) -> Void) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { close(master); close(slave) }
        var t = termios()
        tcgetattr(slave, &t)
        cfmakeraw(&t)
        tcsetattr(slave, TCSANOW, &t)
        let m = master
        let done = DispatchSemaphore(value: 0)
        final class Flag: @unchecked Sendable { var stop = false }
        let flag = Flag()
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 64)
            while !flag.stop {
                var p = pollfd(fd: m, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 20) > 0 else { continue }
                let n = read(m, &buffer, 64)
                if n > 0, let answer = reply(Array(buffer[0..<n])) { _ = write(m, answer, answer.count) }
            }
            done.signal()
        }
        run(String(cString: name))
        flag.stop = true
        done.wait()
    }

    func testProbingAPretendIcom() throws {
        try withPretendRadio(reply: { $0.first == 0xFE ? [0xFE, 0xFE, 0xE0, 0xA2, 0x19, 0x00, 0xA2, 0xFD] : nil }) { path in
            let found = RadioFinder.probe(path)
            XCTAssertEqual(found?.name, "IC-9700")
            XCTAssertEqual(found?.baud, 19200)
        }
    }

    func testProbingAPretendYaesu() throws {
        try withPretendRadio(reply: { String(decoding: $0, as: UTF8.self) == "ID;" ? Array("ID0670;".utf8) : nil }) { path in
            XCTAssertEqual(RadioFinder.probe(path)?.name, "FT-991")
        }
    }

    func testSomethingElseIsNotARadio() throws {
        try withPretendRadio(reply: { _ in nil }) { path in XCTAssertNil(RadioFinder.probe(path)) }
    }

}

final class RotatorTests: XCTestCase {
    func testAzimuthKeepsWithinLimits() {
        let plain = RotatorPlan()
        XCTAssertEqual(plain.azimuth(90, from: 0), 90)
        XCTAssertEqual(plain.azimuth(-10, from: 0), 350)
        XCTAssertEqual(plain.azimuth(370, from: 0), 10)
        XCTAssertEqual(plain.azimuth(5, from: 355), 5, "only one way to get there without going past the limit")
    }

    func testAzimuthUsesTheOverlap() {
        let wide = RotatorPlan(azMax: 450)
        XCTAssertEqual(wide.azimuth(5, from: 355), 365, "carries on across north instead of swinging back")
        XCTAssertEqual(wide.azimuth(5, from: 20), 5)
        XCTAssertEqual(wide.azimuth(95, from: 300), 95, "past the overlap there's only one choice")
        XCTAssertEqual(wide.azimuth(80, from: 400), 440)
    }

    func testFollowsWhenAboveTheLimit() {
        let plan = RotatorPlan(minElevation: 5)
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: 30, riseAz: nil, currentAz: 90, currentEl: 20), .track(az: 100, el: 30))
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: 30, riseAz: nil, currentAz: 99.5, currentEl: 29.5), .hold, "too small to bother the motors")
    }

    func testBelowTheHorizon() {
        let plan = RotatorPlan(minElevation: 5)
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: -20, riseAz: nil, currentAz: 90, currentEl: 20), .hold, "nowhere to be")
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: 2, riseAz: nil, currentAz: 90, currentEl: 20), .hold, "not yet above the lowest it follows")
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: -20, riseAz: 210, currentAz: 90, currentEl: 20), .waitAtRise(az: 210, el: 5))
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: -20, riseAz: 210, currentAz: 210, currentEl: 5), .hold, "already there")
        XCTAssertEqual(plan.action(lookAz: nil, lookEl: nil, riseAz: nil, currentAz: 0, currentEl: 0), .hold)
    }

    func testElevationStaysInRange() {
        let plan = RotatorPlan(elMax: 80)
        XCTAssertEqual(plan.action(lookAz: 100, lookEl: 88, riseAz: nil, currentAz: 90, currentEl: 20), .track(az: 100, el: 80))
    }

    func testRotatorModelList() {
        let list = """
         Rot #  Mfg                    Model                   Version         Status      Macro
             1  Hamlib                 Dummy                   20220531.0      Stable      ROT_MODEL_DUMMY
             2  Hamlib                 NET rotctl              20221110.0      Stable      ROT_MODEL_NETROTCTL
           601  Yaesu                  GS-232A                 20220109.0      Stable      ROT_MODEL_GS232A
           201  Hamlib                 EasycommI               20231219.0      Stable      ROT_MODEL_EASYCOMM1
        """
        let models = RotatorController.parseModels(list)
        XCTAssertEqual(models.map(\.id), [201, 601], "Hamlib's stand-ins are left out")
        XCTAssertEqual(models.last?.name, "Yaesu GS-232A")
    }
}

final class DataUpdateTests: XCTestCase {
    func testAgeWords() {
        XCTAssertEqual(DataUpdates.words(age: 30), "just now")
        XCTAssertEqual(DataUpdates.words(age: 600), "10 min ago")
        XCTAssertEqual(DataUpdates.words(age: 7200), "2 hr ago")
        XCTAssertEqual(DataUpdates.words(age: 5 * 86400), "5 days ago")
    }

    func testOrbitsAreNeverFetchedFasterThanCelesTrakAsks() {
        let orbits = DataUpdates.items.first { $0.file == "gp_active.json" }
        XCTAssertEqual(orbits?.freshFor, 7200)
    }
}

final class SpaceObjectTests: XCTestCase {
    func testHorizonsTable() throws {
        let text = """
        Target body name: James Webb Space Telescope (spacecraft) (-170)
        $$SOE
        2461349.500000000, A.D. 2026-Nov-05 00:00:00.0000,  1.0E+08,  2.0E+07, -3.0E+05, -3.5E+00,  2.5E+01,  1.0E-01,
        2461350.500000000, A.D. 2026-Nov-06 00:00:00.0000,  2.0E+08,  4.0E+07, -6.0E+05, -3.0E+00,  2.0E+01,  2.0E-01,
        $$EOE
        """
        let t = try XCTUnwrap(HorizonsTrack.parse(text))
        XCTAssertEqual(t.points.count, 2)
        XCTAssertEqual(t.points[0].jd, 2461349.5)
        XCTAssertEqual(t.points[0].position, SIMD3(1e8, 2e7, -3e5))
        XCTAssertEqual(t.points[1].velocity.y, 20)
        let middle = try XCTUnwrap(t.at(2461350.0))
        XCTAssertEqual(middle.position.x, 1.5e8, accuracy: 1)
        XCTAssertNil(t.at(2461340), "before what was fetched, it says nothing rather than guess")
        XCTAssertNil(t.at(2461360))
        XCTAssertEqual(t.trail(upTo: 2461350.0).count, 2, "the past, then where it is now")
        XCTAssertNil(HorizonsTrack.parse("No ephemeris for target after 2026"))
    }

    func testHorizonsAddressAsksInUniversalTime() throws {
        let url = Horizons.url(object: -170, centre: 399, now: Date(timeIntervalSince1970: 1_800_000_000), span: Horizons.span(centre: 399, object: -170))
        let items = try XCTUnwrap(URLComponents(string: url)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("COMMAND"), "'-170'")
        XCTAssertEqual(value("CENTER"), "'500@399'")
        XCTAssertEqual(value("TIME_TYPE"), "UT", "at orbital speed a minute's difference is over 100 km")
        XCTAssertEqual(value("REF_PLANE"), "ECLIPTIC")
    }

    func testFetchedPathAlwaysReachesPastNow() throws {
        // With a sample only every two days, stopping just after now would leave nothing to interpolate towards.
        let span = Horizons.span(centre: 399, object: -170)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let items = try XCTUnwrap(URLComponents(string: Horizons.url(object: -170, centre: 399, now: now, span: span))?.queryItems)
        let format = DateFormatter()
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let stop = try XCTUnwrap(items.first { $0.name == "STOP_TIME" }?.value?.replacingOccurrences(of: "'", with: ""))
        let end = try XCTUnwrap(format.date(from: stop))
        XCTAssertGreaterThan(end.timeIntervalSince(now), Double(span.stepMinutes) * 60 + span.keepSeconds)
    }

    func testPlanetsAgainstKnownOrbits() {
        let jd = 2451545.0
        for (name, near, far) in [("Mercury", 0.30, 0.47), ("Venus", 0.71, 0.73), ("Earth", 0.98, 1.02), ("Mars", 1.38, 1.67), ("Jupiter", 4.95, 5.46), ("Saturn", 9.0, 10.1), ("Uranus", 18.2, 20.1), ("Neptune", 29.7, 30.4)] {
            let r = simd_length(Planet.all.first { $0.name == name }!.position(jd: jd))
            XCTAssertGreaterThan(r, near, name)
            XCTAssertLessThan(r, far, name)
        }
        // At J2000 Earth was near perihelion, with the Sun in Sagittarius: about 0.18 AU in x, -0.98 in y.
        let earth = Planet.all[2].position(jd: jd)
        XCTAssertEqual(earth.x, -0.177, accuracy: 0.02)
        XCTAssertEqual(earth.y, 0.967, accuracy: 0.02)
    }

    func testSolarScaleKeepsDirectionAndOrder() {
        let inner = SolarScale.compressed(SIMD3(1, 0, 0)), outer = SolarScale.compressed(SIMD3(30, 0, 0)), far = SolarScale.compressed(SIMD3(0, 170, 0))
        XCTAssertEqual(inner.x, 20, accuracy: 0.001)
        XCTAssertGreaterThan(outer.x, inner.x)
        XCTAssertLessThan(outer.x, 30 * 20, "squeezed")
        XCTAssertEqual(far.x, 0)
        XCTAssertGreaterThan(far.y, outer.x)
    }

    func testSpaceWords() {
        XCTAssertEqual(SpaceWords.distance(384_400), "384,400 km")
        XCTAssertEqual(SpaceWords.distance(1_500_000), "1.50 million km")
        XCTAssertEqual(SpaceWords.distance(Horizons.kmPerAU * 170), "170.00 AU")
        XCTAssertEqual(SpaceWords.lightTime(384_400), "1.3 seconds")
        XCTAssertEqual(SpaceWords.lightTime(Horizons.kmPerAU), "8 minutes")
        XCTAssertEqual(SpaceWords.lightTime(Horizons.kmPerAU * 170), "23.6 hours")
    }

    func testCatalogue() {
        XCTAssertEqual(Set(SpaceCatalog.all.map(\.name)).count, SpaceCatalog.all.count)
        for o in SpaceCatalog.all { XCTAssertTrue(o.horizons != nil || o.norad != nil, o.name) }
        XCTAssertEqual(SpaceCatalog.search("webb").first?.horizons, -170)
        XCTAssertEqual(SpaceCatalog.search("hubble").first?.norad, 20580)
        XCTAssertTrue(SpaceCatalog.search("x").isEmpty, "too little to go on")
        XCTAssertEqual(SpaceCatalog.of(kind: .lunar).map(\.centre), [.moon, .moon, .moon])
    }

}

final class RegistryTests: XCTestCase {
    private let catalogue = """
    #JCAT\tSatcat\tLaunch_Tag\tPiece\tType\tName\tPLName\tLDate\tParent\tSDate\tPrimary\tDDate\tStatus\tDest\tOwner\tState\tManufacturer\tBus\tMotor\tMass
    S50463    \t50463\t2021-130\t2021-130A\tP   D      D\tJWST\tJames Webb Space Telescope\t2021 Dec 25\tS50464\t2021 Dec 25\tEarth\t-\tDSO\tD01093\tGSFC/ESA\tUS\tNGAS/GSFC\tJWST\tTR-500 x 4\t    6161 
    S25544    \t25544\t1998-067\t1998-067A\tP\tZarya\tISS\t1998 Nov 20\t-\t1998 Nov 20\tEarth\t-\tO\t-\tRVSC\tRU\tKHRUN\t-\t-\t-
    S99999    \t99999\t2020-001\t2020-001A\tP\tOther\tOther\t2020\t-\t2020\tEarth\t-\tO\t-\tX\tUS\tX\t-\t-\t1
    """

    func testReadingTheCatalogue() throws {
        let orgs = SatelliteRegistry.organisations("#Code\tU\tS\tT\tC\tT\tT\tShort\tName\nGSFC\tG\tUS\tO\tC\t-\t*\tGSFC\tNASA Goddard Space Flight Center\nNGAS\tS\tUS\tO\tB\t-\t-\tNGAS\tNorthrop Grumman\n")
        let payloads = "#JCAT\tPiece\tName\tLDate\tTLast\tTOp\tTDate\tTF\tProgram\tPlane\tAtt\tMvr\tClass\nS50463\t2021-130A\tJWST\t-\t-\t-\t-\t-\t-\t-\t-\t-\tC\n"
        let found = SatelliteRegistry.parse(catalogue: catalogue, payloads: payloads, organisations: orgs, wanted: [50463, 25544])
        XCTAssertEqual(found.count, 2, "only what was asked for")
        let jwst = try XCTUnwrap(found[50463])
        XCTAssertEqual(jwst.designator, "2021-130A")
        XCTAssertEqual(jwst.operatorName, "NASA Goddard Space Flight Center, ESA", "a code it doesn't know stays as it is")
        XCTAssertEqual(jwst.builder, "Northrop Grumman, NASA Goddard Space Flight Center")
        XCTAssertEqual(jwst.massKg, 6161)
        XCTAssertEqual(jwst.bus, "JWST")
        XCTAssertEqual(jwst.sector, "C")
        let iss = try XCTUnwrap(found[25544])
        XCTAssertEqual(iss.bus, "", "- means nothing recorded")
        XCTAssertNil(iss.massKg)
    }

    func testDesignatorForms() {
        for form in ["1998-067A", "1998067A", "98067A", "98-067A", "1998-067a", " 1998-067A".trimmingCharacters(in: .whitespaces)] {
            XCTAssertEqual(SatelliteRegistry.normalisedDesignator(form), "1998067A", form)
        }
        XCTAssertEqual(SatelliteRegistry.normalisedDesignator("21130"), "2021130", "a whole launch")
        XCTAssertEqual(SatelliteRegistry.normalisedDesignator("2021-130"), "2021130")
        XCTAssertNil(SatelliteRegistry.normalisedDesignator("webb"))
        XCTAssertNil(SatelliteRegistry.normalisedDesignator("25"), "too short to be one")
    }
}

final class AMSATIndexTests: XCTestCase {
    private func row(down: String?, beacon: String? = nil, mode: String?, status: String = "active") -> AMSATFrequencyIndex.Row {
        AMSATFrequencyIndex.Row(name: "X", norad_id: "1", downlink: down, beacon: beacon, mode: mode, status: status)
    }

    func testReadingRows() throws {
        let two = AMSATFrequencyIndex.transmitters(row(down: "145.970/2401.000", mode: "9k6 BPSK/100k GMSK"))
        XCTAssertEqual(two.map(\.downlinkHz), [145_970_000, 2_401_000_000])
        XCTAssertEqual(two.map(\.mode), ["BPSK", "GMSK"])
        XCTAssertEqual(two.map(\.baud), [9600, 100_000])
        XCTAssertEqual(AMSATFrequencyIndex.transmitters(row(down: "145.960", mode: "FM* CTCSS 67.0/200 DUV")).first?.mode, "FM")
        XCTAssertEqual(AMSATFrequencyIndex.transmitters(row(down: "435.310", mode: "1k2/9k6* FSK")).first?.baud, 1200)
        let range = AMSATFrequencyIndex.transmitters(row(down: "145.900-146.000", mode: "SSB")).first
        XCTAssertEqual(range?.downlinkHz, 145_900_000)
        XCTAssertEqual(range?.downlinkHighHz, 146_000_000)
        XCTAssertEqual(AMSATFrequencyIndex.transmitters(row(down: nil, beacon: "145.800", mode: "FM")).first?.mode, "CW")
        XCTAssertTrue(AMSATFrequencyIndex.transmitters(row(down: "435.000", mode: "FM", status: "re-entered")).isEmpty, "off the air")
        XCTAssertTrue(AMSATFrequencyIndex.transmitters(row(down: "not a number", mode: "FM")).isEmpty)
    }

    func testIndexNeverOpensAnUplink() throws {
        // Everything else about these is fine for transmitting, which stays with the fully checked listings.
        let t = try XCTUnwrap(AMSATFrequencyIndex.transmitters(row(down: "145.960", mode: "FM voice repeater")).first)
        XCTAssertNil(t.uplinkLowHz)
        XCTAssertNil(UplinkPolicy.make(t))
    }

    func testMergingKeepsExistingListings() {
        let known = Transmitter(description: "SatNOGS", downlinkHz: 145_800_000, mode: "FM", active: true, baud: nil)
        let same = Transmitter(description: "AMSAT", downlinkHz: 145_802_000, mode: "FM", active: true, baud: nil)
        let new = Transmitter(description: "AMSAT", downlinkHz: 437_000_000, mode: "FM", active: true, baud: nil)
        XCTAssertEqual(AMSATFrequencyIndex.merge([known], with: [same, new]).map(\.description), ["SatNOGS", "AMSAT"])
    }
}

final class SpaceEphemerisTests: XCTestCase {
    private func point(_ jd: Double, _ p: SIMD3<Double>, _ v: SIMD3<Double>) -> HorizonsTrack.Point { .init(jd: jd, position: p, velocity: v) }

    func testSmoothPathFollowsACurve() throws {
        // A circular orbit sampled coarsely: the straight line cuts the corner, and this shouldn't.
        let r = 42_164.0, w = 2 * Double.pi / 86164
        func circle(_ jd: Double) -> HorizonsTrack.Point {
            let a = w * (jd - 2460000) * 86400
            return point(jd, SIMD3(r * cos(a), r * sin(a), 0), SIMD3(-r * w * sin(a), r * w * cos(a), 0))
        }
        let t = HorizonsTrack(points: [circle(2460000), circle(2460000.1)])
        let got = try XCTUnwrap(t.smooth(2460000.05))
        XCTAssertLessThan(abs(simd_length(got.position) - r), 40, "stays on the orbit")
        XCTAssertGreaterThan(abs(simd_length(try XCTUnwrap(t.at(2460000.05)).position) - r), 500, "a straight line wouldn't")
    }

    func testEstimatingPastTheLastFix() throws {
        // Low Earth orbit: two-body from a fix comes back around after one period.
        let r = 7000.0, v = (398_600.4418 / r).squareRoot()
        let period = 2 * Double.pi * r / v
        let start = point(2460000, SIMD3(r, 0, 0), SIMD3(0, v, 0))
        let later = try XCTUnwrap(SpaceEphemeris.extrapolate(start, to: 2460000 + period / 86400))
        XCTAssertLessThan(simd_distance(later.position, start.position), 100)
        XCTAssertNil(SpaceEphemeris.extrapolate(start, to: 2460000 + 4000), "too far to mean anything")
        // Far out: follows the Sun's pull, so a probe keeps going, near its old speed.
        let farOut = point(2460000, SIMD3(2e10, 0, 0), SIMD3(0, 17, 0))
        let farLater = try XCTUnwrap(SpaceEphemeris.extrapolate(farOut, to: 2460030))
        XCTAssertEqual(simd_length(farLater.position) / 2e10, 1, accuracy: 0.05)
    }

    func testEphemerisReportsWhenItIsEstimating() throws {
        let e = SpaceEphemeris(now: 2451545)
        XCTAssertNil(e.state(jd: 2451545), "nothing yet")
        e.set(HorizonsTrack(points: [point(2451545, SIMD3(1e6, 0, 0), .zero), point(2451546, SIMD3(1e6, 1000, 0), .zero)]))
        XCTAssertNotNil(e.state(jd: 2451545.5))
        XCTAssertFalse(e.isEstimated(2451545.5))
        XCTAssertTrue(e.isEstimated(2451550))
        XCTAssertNotNil(e.state(jd: 2451550))
    }

    func testSpacecraftAreSatellites() throws {
        let o = try XCTUnwrap(SpaceCatalog.all.first { $0.name == "James Webb Space Telescope" })
        XCTAssertEqual(o.noradID, 50463)
        XCTAssertEqual(o.designator, "2021-130A")
        let s = Satellite(space: o, ephemeris: SpaceEphemeris())
        XCTAssertEqual(s.orbit, .spacecraft)
        XCTAssertNil(s.state(jd: 2460000))
        XCTAssertNotNil(s.clone())
        for object in SpaceCatalog.all { XCTAssertGreaterThan(object.noradID, 0, object.name) }
        XCTAssertEqual(Set(SpaceCatalog.all.map(\.noradID)).count, SpaceCatalog.all.count)
    }

    func testPrecessionIsSmallAndTrue() {
        let m = SpaceEphemeris.precession(toJD: 2451545)
        XCTAssertEqual((m * SIMD3(1, 0, 0)).x, 1, accuracy: 1e-9)
        let later = SpaceEphemeris.precession(toJD: 2451545 + 36525 * 0.26)
        let angle = acos((later * SIMD3(1, 0, 0)).x) * 180 / .pi
        XCTAssertEqual(angle, 0.36, accuracy: 0.03)
    }
}

final class SatNOGSKeyTests: XCTestCase {
    /// Made up: it only has to look like a key.
    private let sample = String(repeating: "ab12", count: 10)

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("key-test-\(UUID().uuidString)")
    }

    func testOnlyKeysAreAccepted() {
        XCTAssertEqual(SatNOGSKey.clean(" \(sample)\n"), sample)
        XCTAssertNil(SatNOGSKey.clean("short"))
        XCTAssertNil(SatNOGSKey.clean(sample + "00"))
        XCTAssertNil(SatNOGSKey.clean(String(repeating: "z", count: 40)))
    }

    func testSavedPrivately() throws {
        let file = temporaryFile()
        defer { SatNOGSKey.remove(from: file) }
        XCTAssertNil(SatNOGSKey.load(from: file))
        XCTAssertFalse(SatNOGSKey.save("not a key", to: file))
        XCTAssertTrue(SatNOGSKey.save(sample, to: file))
        XCTAssertEqual(SatNOGSKey.load(from: file), sample)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "only this user can read it")
        SatNOGSKey.remove(from: file)
        XCTAssertNil(SatNOGSKey.load(from: file))
    }

    func testReadingFrames() throws {
        let json = #"{"results":[{"sat_id":"X","norad_cat_id":43017,"frame":"3DDB9B","observer":"biGS-PM95rn","timestamp":"2026-11-03T11:04:09Z","decoded":"influxdb"}],"next":null}"#
        let frames = try XCTUnwrap(SatNOGSTelemetry.parse(Data(json.utf8)))
        XCTAssertEqual(frames.first?.hex, "3D DB 9B")
        XCTAssertEqual(frames.first?.observer, "biGS-PM95rn")
        XCTAssertNotNil(frames.first?.date)
        XCTAssertEqual(SatNOGSTelemetry.Frame.spaced(""), "")
        XCTAssertNil(SatNOGSTelemetry.parse(Data("nope".utf8)))
    }

    func testOtherNames() {
        XCTAssertEqual(SatelliteRegistry.otherNames(name: "FOX-1B", names: "AO-91, RADFXSAT"), ["FOX-1B", "AO-91", "RADFXSAT"])
        XCTAssertEqual(SatelliteRegistry.otherNames(name: nil, names: nil), [])
    }
}

final class ConstellationBandTests: XCTestCase {
    func testWhichSatellitesGetABand() throws {
        let starlink = try XCTUnwrap(ConstellationBands.transmitters(forName: "STARLINK-1007").first)
        XCTAssertEqual(starlink.downlinkHz, 11_700_000_000, "tunes to the middle of the band")
        XCTAssertEqual(starlink.mode, "Ku-band 10.7–12.7 GHz")
        XCTAssertEqual(ConstellationBands.transmitters(forName: "NAVSTAR 81 (USA 319)").map(\.downlinkHz), [1_575_420_000, 1_227_600_000, 1_176_450_000])
        XCTAssertEqual(ConstellationBands.transmitters(forName: "GPS BIII-1  (PRN 04)").count, 3)
        XCTAssertEqual(ConstellationBands.transmitters(forName: "COSMOS 2501 (702K)").first?.mode, "GLONASS G1")
        XCTAssertEqual(ConstellationBands.transmitters(forName: "IRIDIUM 106").first?.downlinkHz ?? 0, 1_621_250_000, accuracy: 1)
    }

    func testOthersDoNot() {
        XCTAssertTrue(ConstellationBands.transmitters(forName: "COSMOS 2455").isEmpty, "a military Cosmos isn't GLONASS")
        XCTAssertTrue(ConstellationBands.transmitters(forName: "ISS (ZARYA)").isEmpty)
        XCTAssertTrue(ConstellationBands.transmitters(forName: "QIANFAN-1").isEmpty, "nothing verified to say")
    }

    func testListedAsWhatTheyAre() throws {
        let band = try XCTUnwrap(ConstellationBands.transmitters(forName: "ONEWEB-0012").first)
        XCTAssertEqual(SignalFormat.listed(band), .broadband)
        let gps = try XCTUnwrap(ConstellationBands.transmitters(forName: "NAVSTAR 81").first)
        XCTAssertEqual(SignalFormat.listed(gps), .navigation)
        XCTAssertEqual(SignalFormat.navigation.group, .service)
        XCTAssertNil(UplinkPolicy.make(band), "a downlink band is nothing to transmit on")
        XCTAssertNil(MediaSignal.kind(of: band))
    }

    func testRealListingsWin() throws {
        let real = Transmitter(description: "SatNOGS", downlinkHz: 11_700_001_000, mode: "BPSK", active: true, baud: nil)
        let merged = AMSATFrequencyIndex.merge([real], with: ConstellationBands.transmitters(forName: "STARLINK-1"))
        XCTAssertEqual(merged.map(\.mode), ["BPSK"], "within 5 kHz is the same signal")
        let other = Transmitter(description: "SatNOGS", downlinkHz: 437_000_000, mode: "FM", active: true, baud: nil)
        XCTAssertEqual(AMSATFrequencyIndex.merge([other], with: ConstellationBands.transmitters(forName: "STARLINK-1")).first?.mode, "FM", "the specific one stays first")
    }
}

final class ExtraSatelliteTests: XCTestCase {
    /// A published ISS element set.
    private let iss = ExtraSatellites.Row(tle0: "0 ISS (ZARYA)", tle1: "1 25544U 98067A   26308.88559265  .00005352  00000-0  10457-3 0  9992",
                                          tle2: "2 25544  51.6327 323.8448 0007212 348.6490  11.4335 15.49180468593565")

    func testReadingAnElementSet() throws {
        let (omm, epoch) = try XCTUnwrap(ExtraSatellites.parse(iss))
        XCTAssertEqual(omm.OBJECT_NAME, "ISS (ZARYA)")
        XCTAssertEqual(omm.OBJECT_ID, "1998-067A")
        XCTAssertEqual(omm.NORAD_CAT_ID, 25544)
        XCTAssertEqual(omm.INCLINATION, 51.6327)
        XCTAssertEqual(omm.ECCENTRICITY, 0.0007212, accuracy: 1e-9)
        XCTAssertEqual(omm.MEAN_MOTION, 15.49180468)
        XCTAssertEqual(omm.BSTAR, 0.10457e-3, accuracy: 1e-10)
        XCTAssertEqual(omm.MEAN_MOTION_DOT, 0.00005352)
        XCTAssertEqual(omm.MEAN_MOTION_DDOT, 0)
        let format = ISO8601DateFormatter()
        XCTAssertEqual(epoch.timeIntervalSince(try XCTUnwrap(format.date(from: "2026-11-04T21:15:15Z"))), 0, accuracy: 2, "day 308 of 2026")
        // It has to produce a working orbit too.
        let sat = try XCTUnwrap(Satellite(omm: omm))
        let radius = try XCTUnwrap(sat.state(jd: sat.epochJD)).r
        XCTAssertEqual(simd_length(radius), 6790, accuracy: 40)
    }

    func testSmallNumbers() {
        XCTAssertEqual(ExtraSatellites.assumedDecimal("10457-3") ?? 0, 0.00010457, accuracy: 1e-12)
        XCTAssertEqual(ExtraSatellites.assumedDecimal("-19782-4") ?? 0, -0.000019782, accuracy: 1e-12)
        XCTAssertEqual(ExtraSatellites.assumedDecimal("00000-0"), 0)
        XCTAssertNil(ExtraSatellites.assumedDecimal("        "))
    }

    func testDesignators() {
        XCTAssertEqual(ExtraSatellites.designator("98067A  "), "1998-067A")
        XCTAssertEqual(ExtraSatellites.designator("24182A"), "2024-182A")
    }

    func testBrokenRowsAreSkipped() {
        XCTAssertNil(ExtraSatellites.parse(.init(tle0: "x", tle1: nil, tle2: nil)))
        XCTAssertNil(ExtraSatellites.parse(.init(tle0: "x", tle1: "1 too short", tle2: "2 too short")))
    }

    func testOnlyFreshReportedAndNew() throws {
        let (_, epoch) = try XCTUnwrap(ExtraSatellites.parse(iss))
        XCTAssertEqual(ExtraSatellites.select([iss], transmitting: [25544], known: [], now: epoch).count, 1)
        XCTAssertEqual(ExtraSatellites.select([iss, iss], transmitting: [25544], known: [], now: epoch).count, 1, "once each")
        XCTAssertTrue(ExtraSatellites.select([iss], transmitting: [], known: [], now: epoch).isEmpty, "nobody reports it transmitting")
        XCTAssertTrue(ExtraSatellites.select([iss], transmitting: [25544], known: [25544], now: epoch).isEmpty, "already listed")
        XCTAssertTrue(ExtraSatellites.select([iss], transmitting: [25544], known: [], now: epoch.addingTimeInterval(15 * 86400)).isEmpty, "too old to trust")
    }

    func testDecayFallsBackToAnEstimate() throws {
        // Very low with heavy drag, like a satellite about to come down, some days after its fix.
        let low = ExtraSatellites.Row(tle0: "0 LOW", tle1: "1 99999U 04047A   26300.00000000  .50000000  00000-0  50000-1 0  9990",
                                      tle2: "2 99999  20.5442 166.9355 0004514 299.2068  60.7938 16.40000000  9990")
        let sat = try XCTUnwrap(ExtraSatellites.parse(low).flatMap { Satellite(omm: $0.omm) })
        let later = sat.epochJD + 10
        let state = try XCTUnwrap(sat.state(jd: later), "still gives a place to draw it")
        XCTAssertGreaterThan(simd_length(state.r), 6378)
        XCTAssertTrue(sat.isDecayEstimate)
        XCTAssertNil(sat.state(jd: sat.epochJD + 30), "too long after its last orbit to say anything")
    }
}

final class ReceiverRangeTests: XCTestCase {
    private func satellite(_ downlinks: [Double]) throws -> Satellite {
        let row = ExtraSatellites.Row(tle0: "0 TEST", tle1: "1 25544U 98067A   26308.88559265  .00005352  00000-0  10457-3 0  9992",
                                      tle2: "2 25544  51.6327 323.8448 0007212 348.6490  11.4335 15.49180468593565")
        let sat = try XCTUnwrap(ExtraSatellites.parse(row).flatMap { Satellite(omm: $0.omm) })
        sat.transmitters = downlinks.map { Transmitter(description: "", downlinkHz: $0, mode: "FM", active: true, baud: nil) }
        return sat
    }

    func testRadioRanges() throws {
        let rtl = try XCTUnwrap(SDRCatalog.tunableRanges("rtlsdr"))
        XCTAssertTrue(try satellite([145_800_000]).isReachable(by: rtl))
        XCTAssertTrue(try satellite([1_000, 137_000_000]).isReachable(by: rtl), "one downlink in range is enough")
        XCTAssertFalse(try satellite([11_700_000_000]).isReachable(by: rtl), "Ku-band is far above it")
        XCTAssertFalse(try satellite([]).isReachable(by: rtl), "no known frequency, so it can't claim to be tunable")
        let hf = try XCTUnwrap(SDRCatalog.tunableRanges("airspyhf"))
        XCTAssertTrue(try satellite([145_800_000]).isReachable(by: hf))
        XCTAssertFalse(try satellite([437_000_000]).isReachable(by: hf), "a gap between its two bands and above")
        XCTAssertNil(SDRCatalog.tunableRanges("net_source"), "could be anything at the other end")
    }

    func testInactiveDownlinksDoNotCount() throws {
        let sat = try satellite([])
        sat.transmitters = [Transmitter(description: "", downlinkHz: 145_800_000, mode: "FM", active: false, baud: nil)]
        XCTAssertFalse(sat.isReachable(by: [100e6...200e6]))
        sat.decoderFrequencyHz = 137_100_000
        XCTAssertTrue(sat.isReachable(by: [100e6...200e6]), "a decoder's frequency counts too")
    }

    func testHostsReadAsOneSpan() {
        let merged = SDRCatalog.merged([24e6...1800e6, 0...30e6, 2000e6...3000e6, 2500e6...2600e6])
        XCTAssertEqual(merged, [0...1800e6, 2000e6...3000e6])
        XCTAssertEqual(SDRCatalog.describe([24e6...1766e6]), "24 MHz to 1.766 GHz")
        XCTAssertEqual(SDRCatalog.describe([1e6...6e9]), "1 MHz to 6 GHz")
    }

    func testFilter() {
        var f = SatelliteFilter(withinReceiver: true)
        XCTAssertEqual(f.activeCount, 1)
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, reachable: true))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, reachable: false))
        f.withinReceiver = false
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, reachable: false))
    }
}

@MainActor
final class GPSFixTests: XCTestCase {
    private var rtl: SDRSource { SDRCatalog.sources.first { $0.id == "rtlsdr" }! }

    func testRecordingsGoSomewhereGNSSSDRCanRead() {
        // It cut a path of about 200 characters short at 177, and quit saying it couldn't open the file.
        let c = FileManager.default.temporaryDirectory.path + "/gpsfix/12345678/gps.cs16"
        XCTAssertLessThan(c.count, 150)
        XCTAssertFalse(c.contains(" "))
        XCTAssertEqual(GPSFixPlan.processingArguments(config: "/a.conf", logFolder: "/w"), ["--config_file=/a.conf", "--log_dir=/w"])
    }

    func testUsesTheCopyInsideTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gps-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(GPSFixPlan.findGNSSSDR(in: dir))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("GNSS/bin"), withIntermediateDirectories: true)
        let exe = try script("gnss-sdr", "exit 0", in: dir.appendingPathComponent("GNSS/bin"))
        XCTAssertEqual(GPSFixPlan.findGNSSSDR(in: dir)?.standardizedFileURL.path, exe.standardizedFileURL.path)
    }

    /// Runs when pointed at GNSS-SDR's published recording, through the same steps as the app, with only
    /// the receiver stood in for. The answer should match the reference track published with the recording.
    func testARealRecordingGivesTheRealPlace() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let exe = env["GNSS_SDR_BIN"], let recording = env["GNSS_SAMPLE"] else { throw XCTSkip("Not pointed at a recording") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try script("engine", #"ln "\#(recording)" "$3.cs16""#, in: dir)
        let c = GPSFixController(workRoot: dir.appendingPathComponent("w"))
        let started = Date()
        c.start(.init(source: rtl, sampleRate: 4_000_000), seconds: 1, engine: engine, gnssSDR: URL(fileURLWithPath: exe))
        while c.isBusy, Date().timeIntervalSince(started) < 600 { try? await Task.sleep(for: .milliseconds(200)) }
        guard case .found(let fix) = c.stage else { return XCTFail("\(c.stage)") }
        print("REALGPS seconds=\(Int(Date().timeIntervalSince(started))) lat=\(fix.latitude) lon=\(fix.longitude) h=\(fix.height) spread=\(fix.spread) readings=\(fix.readings)")
        XCTAssertEqual(fix.latitude, 41.27474, accuracy: 0.0005)
        XCTAssertEqual(fix.longitude, 1.98749, accuracy: 0.0005)
        XCTAssertLessThan(fix.spread, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording), "only the link is deleted")
    }

    private func source(_ id: String) -> SDRSource { SDRCatalog.sources.first { $0.id == id }! }

    private func readiness(_ id: String, address: String = "", device: String? = nil, rate: Double = 2e6) -> GPSFixPlan.Readiness {
        GPSFixPlan.readiness(source: source(id), address: address, connectedDevice: device, listenerRate: rate)
    }

    func testAnyReceiverOfYourOwnWillDo() {
        XCTAssertEqual(readiness("rtlsdr", device: "RTL-SDR Blog V4"), .ready)
        XCTAssertEqual(readiness("hackrf", device: "HackRF One"), .ready)
        XCTAssertEqual(readiness("rtltcp", address: "192.168.1.5"), .ready)
        XCTAssertEqual(readiness("plutosdr", address: "192.168.2.1"), .ready)
        XCTAssertEqual(readiness("sdrpp_server", address: "10.0.0.2", rate: 2.4e6), .ready)
    }

    func testOtherwiseItSaysToChooseInListener() {
        func says(_ r: GPSFixPlan.Readiness, _ word: String, line: UInt = #line) {
            guard case .needsSource(let m) = r else { return XCTFail("\(r)", line: line) }
            XCTAssertTrue(m.contains(word), m, line: line)
            XCTAssertTrue(m.contains("Listener") || m.contains("Capture"), m, line: line)
        }
        says(readiness("spyserver"), "someone else's station")
        says(readiness("websdr"), "browser")
        says(readiness("airspyhf", device: "AirspyHF+"), "can't receive GPS")
        says(readiness("rtltcp"), "no address")
        says(readiness("rtlsdr"), "No RTL-SDR is plugged in")
        says(readiness("sdrpp_server", address: "10.0.0.2", rate: 1e6), "2 MS/s")
    }

    func testRecordsTheL1BandFromWhateverIsConnected() {
        let usb = GPSFixPlan.Receiver(source: rtl, sampleRate: 2e6, gain: GPSFixPlan.gain(for: rtl))
        let off = GPSFixPlan.engineArguments(usb, output: "/x/gps", seconds: 120)
        XCTAssertEqual(Array(off.prefix(3)), ["legacy", "record", "/x/gps"])
        for pair in [["--frequency", "1575420000"], ["--samplerate", "2000000"], ["--baseband_format", "cs16"], ["--timeout", "120"], ["--gain", "39"]] {
            let i = off.firstIndex(of: pair[0])
            XCTAssertEqual(i.map { off[$0 + 1] }, pair[1], pair[0])
        }
        XCTAssertFalse(off.contains("--bias"))
        var powered = usb
        powered.bias = true
        XCTAssertTrue(GPSFixPlan.engineArguments(powered, output: "/x/gps", seconds: 120).contains("--bias"))

        let net = GPSFixPlan.engineArguments(.init(source: source("rtltcp"), address: "192.168.1.5", port: 1234, sampleRate: 2e6), output: "/x/gps", seconds: 120)
        XCTAssertEqual(net.firstIndex(of: "--ip_address").map { net[$0 + 1] }, "192.168.1.5")
        XCTAssertEqual(net.firstIndex(of: "--port").map { net[$0 + 1] }, "1234")
        XCTAssertFalse(net.contains("--gain"), "left to automatic")
        XCTAssertEqual(GPSFixPlan.sampleRate(for: source("sdrpp_server"), listenerRate: 2.4e6), 2.4e6, "whatever its server sends")
        XCTAssertEqual(GPSFixPlan.sampleRate(for: source("airspy"), listenerRate: 1e6), 3e6)
    }

    func testConfigurationAsksForGeoJSONFromTheRecording() {
        let c = GPSFixPlan.configuration(recording: "/w/gps.cs16", rate: 2_000_000, outputFolder: "/w/out")
        for line in ["SignalSource.filename=/w/gps.cs16", "SignalSource.item_type=ishort", "GNSS-SDR.internal_fs_sps=2000000",
                     "SignalSource.sampling_frequency=2000000", "PVT.geojson_output_enabled=true", "PVT.output_path=/w/out",
                     "SignalSource.repeat=false"] {
            XCTAssertTrue(c.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.contains(line), line)
        }
    }

    /// Exactly what GNSS-SDR's GeoJSON printer writes.
    private let geojson = """
    {
      "type":  "Feature",
      "properties": {
           "name": "Locations generated by GNSS-SDR"\u{20}
       },
      "geometry": {
          "type": "MultiPoint",
          "coordinates": [
           [1.9877, 41.2748, 80.5],
           [1.98771, 41.27481, 81],
           [-1.5e1, 4.1e1, 1.2e2]
           ]
       }
    }
    """

    func testReadsGeoJSONWholeOrCutOff() {
        XCTAssertEqual(GPSFixPlan.points(inGeoJSON: geojson).count, 3)
        XCTAssertEqual(GPSFixPlan.points(inGeoJSON: geojson)[0], .init(longitude: 1.9877, latitude: 41.2748, height: 80.5))
        XCTAssertEqual(GPSFixPlan.points(inGeoJSON: geojson)[2].longitude, -15)
        let cut = String(geojson.prefix(while: { $0 != "]" })) + "]"
        XCTAssertEqual(GPSFixPlan.points(inGeoJSON: cut).count, 1)
    }

    func testAFixIgnoresWildReadingsAndSettling() throws {
        var points = (0..<100).map { GPSFixPlan.Point(longitude: 10 + Double($0 % 3) * 1e-5, latitude: 20 + Double($0 % 3) * 1e-5, height: 5) }
        points.insert(.init(longitude: 150, latitude: -70, height: 1000), at: 0)
        points.append(.init(longitude: 10, latitude: 20, height: 900_000))
        let fix = try XCTUnwrap(GPSFixPlan.fix(from: points))
        XCTAssertEqual(fix.latitude, 20, accuracy: 1e-4)
        XCTAssertEqual(fix.longitude, 10, accuracy: 1e-4)
        XCTAssertLessThan(fix.spread, 10)
        XCTAssertNil(GPSFixPlan.fix(from: Array(points.prefix(2))))
        XCTAssertNil(GPSFixPlan.fix(from: [.init(longitude: 0, latitude: 0, height: 0)]))
    }

    func testAFixAcrossTheDateLineStaysThere() throws {
        let points = (0..<20).map { GPSFixPlan.Point(longitude: $0 % 2 == 0 ? 179.99999 : -179.99999, latitude: -10, height: 0) }
        let fix = try XCTUnwrap(GPSFixPlan.fix(from: points))
        XCTAssertGreaterThan(abs(fix.longitude), 179.9)
        XCTAssertLessThan(fix.spread, 20)
    }

    func testCoordinatesAreWrittenTheGoogleMapsWay() {
        XCTAssertEqual(SavedLocation.coordinates(latitude: 41.274836, longitude: -1.987689), "41.27484, -1.98769")
        XCTAssertEqual(SavedLocation.googleMapsURL(latitude: 41.274836, longitude: -1.987689)?.absoluteString, "https://www.google.com/maps?q=41.274836,-1.987689")
    }

    func testAWeakPositionSaysWhyBeforeItsPinned() {
        func fix(used: Int?, spread: Double, readings: Int) -> GPSFixPlan.Fix {
            .init(latitude: 1, longitude: 2, height: 0, spread: spread, readings: readings, satellitesUsed: used)
        }
        XCTAssertEqual(fix(used: 6, spread: 5, readings: 500).warnings, [])
        XCTAssertTrue(fix(used: 4, spread: 5, readings: 500).warnings[0].contains("Only 4 satellites"))
        XCTAssertTrue(fix(used: 6, spread: 2400, readings: 500).warnings[0].contains("about 2 km"))
        XCTAssertTrue(fix(used: 6, spread: 5, readings: 10).warnings[0].contains("10 readings"))
        XCTAssertEqual(fix(used: 4, spread: 2400, readings: 10).warnings.count, 3)
    }

    func testReadsSatellitesAndErrorsFromRealOutput() {
        // Lines from a real run of GNSS-SDR, and of the engine with no receiver attached.
        XCTAssertEqual(GPSFixPlan.observations(inLine: "\u{1B}[1;32mPosition at 2032-Nov-18 06:24:44.500000 UTC using 5 observations is Lat = 41.274846 [deg], Long = 1.987660 [deg]"), 5)
        XCTAssertNil(GPSFixPlan.observations(inLine: "Velocity: East: -0.24 [m/s]"))
        XCTAssertEqual(GPSFixPlan.errorText(inLine: "[10:38:06 - 05/11/2026] \u{1B}[31m(E) Could not find a handler for source type : rtlsdr!\u{1B}[m"), "Could not find a handler for source type : rtlsdr!")
        XCTAssertNil(GPSFixPlan.errorText(inLine: "(E) Could not open the SDRPlay API, perhaps the service is not running?"), "logged on every run")
        XCTAssertEqual(GPSFixPlan.errorText(inLine: "E1105 18:58:26.016257 2173617 gnss_flowgraph.cc:771] Can't connect signal source block 0 internally: can't open file"), "Can't connect signal source block 0 internally: can't open file")
        XCTAssertNil(GPSFixPlan.errorText(inLine: "Tracking of GPS L1 C/A signal started on channel 0"))
    }

    func testCountsSatellitesFromItsOutput() {
        XCTAssertEqual(GPSFixPlan.satellite(inLine: "Tracking of GPS L1 C/A signal started on channel 4 for satellite GPS PRN 21 (Block IIR-M)"), 21)
        XCTAssertNil(GPSFixPlan.satellite(inLine: "Loss of lock in channel 4!"))
    }

    func testSavedLocationsLastUntilRemoved() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "GPSFixTests-\(UUID())"))
        XCTAssertEqual(SavedLocation.load(from: d), [])
        let place = SavedLocation(name: "GPS 1°, 2°", latitude: 1, longitude: 2, iso: "", saved: Date(timeIntervalSince1970: 1000))
        SavedLocation.store([place], in: d)
        XCTAssertEqual(SavedLocation.load(from: d), [place])
        SavedLocation.store([], in: d)
        XCTAssertEqual(SavedLocation.load(from: d), [])
    }

    // MARK: The whole run, with small scripts standing in for the two programs

    private func script(_ name: String, _ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Writes as much as a real recording would be, to the path it was given.
    private let engine = #"dd if=/dev/zero of="$3.cs16" bs=1000000 count=8 2>/dev/null"#

    private func gnss(_ rows: String) -> String {
        #"""
        conf="${1#--config_file=}"
        grep -q geojson_output_enabled=true "$conf" || exit 9
        out=$(sed -n 's/.*PVT.output_path=//p' "$conf")
        echo "Tracking of GPS L1 C/A signal started on channel 0 for satellite GPS PRN 05 (Block IIF)"
        echo "Position at 2032-Nov-18 06:24:44.500000 UTC using 5 observations is Lat = 12.25 [deg]"
        \#(rows)
        """#
    }

    private func wait(_ c: GPSFixController) async {
        for _ in 0..<200 where c.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func testAWholeRunFindsThePositionAndDeletesTheRecording() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gps-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        let c = GPSFixController(workRoot: work)
        let rows = #"printf '[-30.5, 12.25, 3], [-30.5, 12.25, 3], [-30.5, 12.25, 3], [-30.5, 12.25, 3]' > "$out/PVT_1.geojson""#
        c.start(.init(source: rtl, sampleRate: 2e6), seconds: 1, engine: try script("engine", engine, in: dir), gnssSDR: try script("gnss", gnss(rows), in: dir))
        XCTAssertTrue(c.isBusy)
        await wait(c)
        guard case .found(let fix) = c.stage else { return XCTFail("\(c.stage)") }
        XCTAssertEqual(fix.latitude, 12.25)
        XCTAssertEqual(fix.longitude, -30.5)
        XCTAssertEqual(fix.satellitesUsed, 5)
        XCTAssertEqual(fix.satellitesHeard, 1)
        for _ in 0..<50 {
            if ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [], [], "the recording is deleted")
    }

    func testAnEmptySkySaysWhatItHeard() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gps-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = GPSFixController(workRoot: dir.appendingPathComponent("work"))
        c.start(.init(source: rtl, sampleRate: 2e6), seconds: 1, engine: try script("engine", engine, in: dir), gnssSDR: try script("gnss", gnss("true"), in: dir))
        await wait(c)
        guard case .failed(let message) = c.stage else { return XCTFail("\(c.stage)") }
        XCTAssertTrue(message.contains("Heard 1 satellite,"), message)
        XCTAssertEqual(c.satellitesHeard, 1, "shown beside the message")
    }

    func testANoReceiverRunFailsPlainly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gps-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = GPSFixController(workRoot: dir.appendingPathComponent("work"))
        c.start(.init(source: rtl, sampleRate: 2e6), seconds: 1, engine: try script("engine", "exit 1", in: dir), gnssSDR: try script("gnss", "exit 0", in: dir))
        await wait(c)
        guard case .failed(let message) = c.stage else { return XCTFail("\(c.stage)") }
        XCTAssertTrue(message.contains("plugged in"), message)
    }

    func testCancelStopsAndCleansUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gps-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = GPSFixController(workRoot: dir.appendingPathComponent("work"))
        c.start(.init(source: rtl, sampleRate: 2e6), seconds: 1, engine: try script("engine", "exec sleep 30", in: dir), gnssSDR: try script("gnss", "exit 0", in: dir))
        try? await Task.sleep(for: .milliseconds(300))
        c.cancel()
        await wait(c)
        XCTAssertEqual(c.stage, .ready)
    }
}

final class SignalLabelTests: XCTestCase {
    func testBands() {
        XCTAssertEqual(SignalLabel.band(hz: 14_000_000)?.text, "HF")
        XCTAssertEqual(SignalLabel.band(hz: 145_960_000)?.text, "VHF")
        XCTAssertEqual(SignalLabel.band(hz: 435_000_000)?.text, "UHF")
        XCTAssertEqual(SignalLabel.band(hz: 1_575_420_000)?.text, "L")
        XCTAssertEqual(SignalLabel.band(hz: 2_400_000_000)?.text, "S")
        XCTAssertEqual(SignalLabel.band(hz: 10_460_000_000)?.text, "X")
        XCTAssertEqual(SignalLabel.band(hz: 11_700_000_000)?.text, "X")
        XCTAssertNil(SignalLabel.band(hz: 0))
    }

    func testReadsRealListings() {
        func names(_ mode: String) -> [String] { SignalLabel.modes(in: mode).map(\.text) }
        XCTAssertEqual(names("9k6BPSK* QSPK FM* SSDV*"), ["BPSK", "QPSK", "FM", "SSDV"])
        XCTAssertEqual(names("FM* CTCSS 67.0/200 DUV"), ["FM", "DUV"])
        XCTAssertEqual(names("1k2/4k8*/9k6 FSK APRS FM"), ["FSK", "APRS", "FM"])
        XCTAssertEqual(names("VHF/UHF SSB"), ["SSB"])
        XCTAssertEqual(names("FSK AX.100 Mode 5"), ["FSK"])
        XCTAssertEqual(names("GFSK"), ["GFSK"], "not FSK as well")
        XCTAssertEqual(names("UNKNOWN"), [])
        XCTAssertEqual(SignalLabel.all(hz: 435_000_000, mode: "BPSK").map(\.text), ["UHF", "BPSK"])
    }

    func testEveryTypeHasItsOwnColourThatWhiteTextReadsOn() {
        for color in SignalLabel.everyColor {
            XCTAssertGreaterThanOrEqual(SignalLabel.contrastWithWhite(color), 4.5, String(color, radix: 16))
        }
        let shown = SignalLabel.modes(in: "BPSK QPSK FM AM SSB USB LSB CW GMSK GFSK AFSK FSK MSK LORA SSTV SSDV APRS OFDM DUV JAS DVB-S2")
        XCTAssertEqual(Set(shown.map(\.color)).count, shown.count)
    }
}

final class RTLTunerTests: XCTestCase {
    func testReadsTheChipFromTheDriversLines() {
        XCTAssertEqual(RTLTuner.parse("Found Rafael Micro R820T tuner"), .r820t)
        XCTAssertEqual(RTLTuner.parse("Found Rafael Micro R828D tuner\nRTL-SDR Blog V4 Detected"), .blogV4)
        XCTAssertEqual(RTLTuner.parse("Found Elonics E4000 tuner"), .e4000)
        XCTAssertEqual(RTLTuner.parse("Found Fitipower FC0013 tuner"), .fc0013)
        XCTAssertEqual(RTLTuner.parse("Found FCI 2580 tuner"), .fc2580)
        XCTAssertNil(RTLTuner.parse("Device RTL-TCP"))
    }

    func testRangesDifferByChip() {
        func reaches(_ t: RTLTuner, _ mhz: Double) -> Bool { t.ranges.contains { $0.contains(mhz * 1e6) } }
        XCTAssertTrue(reaches(.r820t, 137))
        XCTAssertTrue(reaches(.r820t, 1575.42))
        XCTAssertFalse(reaches(.r820t, 7), "shortwave needs the V4's upconverter")
        XCTAssertTrue(reaches(.blogV4, 7))
        XCTAssertFalse(reaches(.r820t, 11_700), "Starlink")
        XCTAssertFalse(reaches(.e4000, 1200), "its gap")
        XCTAssertTrue(reaches(.e4000, 2000))
        XCTAssertFalse(reaches(.fc0012, 1575.42))
        XCTAssertFalse(reaches(.fc2580, 400))
    }

    func testPicksADownlinkItCanReach() {
        func tx(_ hz: Double, active: Bool = true) -> Transmitter { Transmitter(description: "", downlinkHz: hz, mode: "FM", active: active, baud: nil) }
        let r = RTLTuner.r820t.ranges
        XCTAssertEqual(SDRCatalog.reachableDownlink(of: [tx(11.7e9), tx(437e6)], in: r), 437e6)
        XCTAssertNil(SDRCatalog.reachableDownlink(of: [tx(11.7e9), tx(437e6, active: false)], in: r))
    }
}

final class ScanBandRangeTests: XCTestCase {
    func testBandsOutsideTheReceiverAreLeftOut() {
        let weather = ScanBand.all.first { $0.name.hasPrefix("VHF weather") }!
        XCTAssertTrue(weather.isReachable(by: nil), "nothing known, so nothing hidden")
        XCTAssertTrue(weather.isReachable(by: RTLTuner.r820t.ranges))
        XCTAssertFalse(weather.isReachable(by: RTLTuner.fc2580.ranges))
    }
}

final class SignalMeterTests: XCTestCase {
    /// Gently uneven noise, the way a real spectrum looks.
    private func noise(floor: Float = -80, _ change: (inout [Float]) -> Void = { _ in }) -> [Float] {
        var v = (0..<1024).map { floor + Float(($0 * 37) % 17) / 8 }
        change(&v)
        return v
    }

    func testTheReceiversOwnCentreSpikeIsNotASignal() {
        // As measured on an RTL-SDR at gain 0: a spike 12 dB up in the very middle, and nothing else.
        XCTAssertEqual(SatDumpRunner.spectrumSNR(noise { $0[512] += 12; $0[511] += 6; $0[513] += 6 }), 0)
    }

    func testARealSignalBesideTheCentreCounts() {
        let snr = SatDumpRunner.spectrumSNR(noise { for i in 600...604 { $0[i] = -60 } })
        XCTAssertEqual(snr, 15, accuracy: 2)
    }

    func testFilterRollOffAtTheEdgesIsIgnored() {
        XCTAssertEqual(SatDumpRunner.spectrumSNR(noise { $0[3] = -40; $0[1020] = -40 }), 0)
    }

    func testGainThatLiftsNoiseAndSignalTogetherChangesNothing() {
        let quiet = SatDumpRunner.spectrumSNR(noise(floor: -80) { for i in 600...604 { $0[i] = -60 } })
        let loud = SatDumpRunner.spectrumSNR(noise(floor: -60) { for i in 600...604 { $0[i] = -40 } })
        XCTAssertEqual(quiet, loud, accuracy: 0.01)
    }
}

final class RegistryDesignatorTests: XCTestCase {
    func testTheLookUpLinkShowsOnlyWhenSomethingIsMissing() {
        XCTAssertEqual(SatelliteRegistry.orbitalRadarPage(norad: 101093)?.absoluteString, "https://orbitalradar.com/satellite/101093")
        XCTAssertTrue(SatelliteRegistry.isMissingDetails(nil))
        XCTAssertTrue(SatelliteRegistry.isMissingDetails(RegistryEntry(operatorName: "A", builder: "B", massKg: nil, bus: "C")))
        XCTAssertFalse(SatelliteRegistry.isMissingDetails(RegistryEntry(operatorName: "A", builder: "B", massKg: 1, bus: "C")))
    }

    private func line(_ number: String, _ piece: String, owner: String) -> String {
        var f = [String](repeating: "-", count: 20)
        f[0] = "S1"; f[1] = number; f[3] = piece; f[14] = owner; f[19] = "10"
        return f.joined(separator: "\t")
    }

    func testFallsBackToTheDesignator() {
        let found = SatelliteRegistry.parse(catalogue: line("44999", "2019-032A", owner: "ACME"), payloads: nil, organisations: [:], wanted: [44310], designators: ["2019-032A": 44310])
        XCTAssertEqual(found[44310]?.massKg, 10)
    }

    func testAMatchingNumberWins() {
        let catalogue = [line("44999", "2019-032A", owner: "WRONG"), line("44310", "2019-999Z", owner: "RIGHT")].joined(separator: "\n")
        let found = SatelliteRegistry.parse(catalogue: catalogue, payloads: nil, organisations: [:], wanted: [44310], designators: ["2019-032A": 44310])
        XCTAssertEqual(found[44310]?.designator, "2019-999Z")
    }

    func testNoMatchMeansNoEntry() {
        XCTAssertNil(SatelliteRegistry.parse(catalogue: line("1", "1957-001A", owner: "X"), payloads: nil, organisations: [:], wanted: [101093], designators: ["2026-227CF": 101093])[101093])
    }
}

final class SatNOGSIdentityTests: XCTestCase {
    private func row(_ n: Int, follow: Int? = nil, _ name: String, _ names: String = "", status: String = "in orbit") -> SatNOGSIdentity.Row {
        .init(norad_cat_id: n, norad_follow_id: follow, name: name, names: names, status: status)
    }
    private let catalog = [(norad: 101093, name: "NIS-PQ"), (norad: 43017, name: "RADFXSAT (FOX-1B)"), (norad: 1, name: "TWIN"), (norad: 2, name: "TWIN")]

    func testTheOneThatStartedThis() {
        XCTAssertEqual(SatNOGSIdentity.aliases([row(98225, "NIS-PQ", "QUBIK-5")], catalog: catalog), [98225: 101093], "the extra name is one the catalogue doesn't use")
    }

    func testFollowsTheRealNumberWhenGiven() {
        XCTAssertEqual(SatNOGSIdentity.aliases([row(99676, follow: 43017, "Aurora")], catalog: catalog), [99676: 43017])
    }

    func testMatchesWhatsInBrackets() {
        XCTAssertEqual(SatNOGSIdentity.aliases([row(99000, "Fox-1B")], catalog: catalog), [99000: 43017])
    }

    func testWontGuess() {
        XCTAssertEqual(SatNOGSIdentity.aliases([row(98000, "TWIN")], catalog: catalog), [:], "two with that name")
        XCTAssertEqual(SatNOGSIdentity.aliases([row(98000, "Unknown")], catalog: [(norad: 5, name: "UNKNOWN")]), [:])
        XCTAssertEqual(SatNOGSIdentity.aliases([row(98000, "OBJECT A")], catalog: [(norad: 5, name: "OBJECT A")]), [:])
        XCTAssertEqual(SatNOGSIdentity.aliases([row(50000, "NIS-PQ")], catalog: catalog), [:], "a real number means a different satellite")
        XCTAssertEqual(SatNOGSIdentity.aliases([row(98225, "NIS-PQ", status: "re-entered")], catalog: catalog), [:])
        XCTAssertEqual(SatNOGSIdentity.aliases([row(101093, "NIS-PQ")], catalog: catalog), [:], "already the same number")
        XCTAssertEqual(SatNOGSIdentity.aliases([row(98000, "NIS-PQ", "Fox-1B")], catalog: catalog), [:], "its names point at two satellites")
    }
}

final class TalkThroughTests: XCTestCase {
    private func row(_ status: String, uplink: String? = "145.900", mode: String = "FM") -> AMSATFrequencyIndex.Row {
        AMSATFrequencyIndex.Row(name: "X", norad_id: "1", downlink: "435.000", beacon: nil, mode: mode, status: status, uplink: uplink)
    }

    func testOnlyWhatIsStillUpCanBeShown() {
        XCTAssertEqual(row("active").talkThrough, [.fmRepeater])
        XCTAssertEqual(row("inactive").talkThrough, [.fmRepeater], "still up there")
        XCTAssertEqual(row("unknown").talkThrough, [.fmRepeater])
        XCTAssertEqual(row("re-entered").talkThrough, [])
        XCTAssertEqual(row("to be launched").talkThrough, [])
        XCTAssertEqual(row("failure").talkThrough, [])
    }

    func testAnFMDownlinkWithNoUplinkIsNotARepeater() {
        XCTAssertEqual(row("active", uplink: nil).talkThrough, [])
        XCTAssertEqual(row("active", uplink: " ").talkThrough, [])
    }

    func testModesSortIntoKinds() {
        XCTAssertEqual(CommunicationKind.listed(mode: "SSB CW"), [.linear])
        XCTAssertEqual(CommunicationKind.listed(mode: "9k6 FSK"), [.digital])
        XCTAssertEqual(CommunicationKind.listed(mode: "1k2/9k6 FSK APRS FM"), [.digital, .fmRepeater])
    }

    func testNamesMatchWithOrWithoutBrackets() {
        XCTAssertEqual(AMSATFrequencyIndex.nameKeys("RADFXSAT (FOX-1B)"), ["RADFXSATFOX1B", "RADFXSAT", "FOX1B"])
        XCTAssertEqual(AMSATFrequencyIndex.nameKeys("Fox-1B"), ["FOX1B"])
        XCTAssertEqual(AMSATFrequencyIndex.nameKeys("TEVEL2-1"), ["TEVEL21"])
    }

    func testCategoryFilters() {
        var f = SatelliteFilter()
        f.category = .weather
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(f.activeCount, 1)
        XCTAssertTrue(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, category: .weather))
        XCTAssertFalse(f.matches(launchYear: nil, encryption: .no, hasFrequency: true, category: .military))
    }
}

final class NoDecoderTests: XCTestCase {
    private func satellite(mode: String) throws -> Satellite {
        let row = ExtraSatellites.Row(tle0: "0 TEST", tle1: "1 99999U 04047A   26300.00000000  .00000000  00000-0  00000-0 0  9990",
                                      tle2: "2 99999  20.5442 166.9355 0004514 299.2068  60.7938 15.40000000  9990")
        let sat = try XCTUnwrap(ExtraSatellites.parse(row).flatMap { Satellite(omm: $0.omm) })
        sat.transmitters = [Transmitter(description: "Downlink", downlinkHz: 145_960_000, mode: mode, active: true, baud: 9600)]
        return sat
    }

    /// A catalogue holding only what's in the file it's given.
    private func catalog(_ json: String) throws -> (PipelineCatalog, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipes-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("pipelines"), withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("pipelines/p.json"), atomically: true, encoding: .utf8)
        return (PipelineCatalog(resourcesDir: dir, rules: []), dir)
    }

    func testTheDemodulatorIsTheDefaultAndSaysWhy() throws {
        let (c, dir) = try catalog(#"{"analog_demod":{"name":"Analog Demodulation","live":true}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tune = c.select(for: try satellite(mode: "DUV"))
        XCTAssertEqual(tune.pipeline?.id, "analog_demod")
        XCTAssertTrue(tune.noDecoder, "so the warning stays")
        XCTAssertEqual(tune.frequencyHz, 145_960_000)
    }

    func testAnAnalogSignalIsNotAWarning() throws {
        let (c, dir) = try catalog(#"{"analog_demod":{"name":"Analog Demodulation","live":true}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tune = c.select(for: try satellite(mode: "FM"))
        XCTAssertEqual(tune.pipeline?.id, "analog_demod")
        XCTAssertFalse(tune.noDecoder, "the demodulator is the right tool for FM")
    }

    func testWithoutTheDemodulatorItStillSavesToFile() throws {
        let (c, dir) = try catalog(#"{"other":{"name":"Other","live":true}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tune = c.select(for: try satellite(mode: "DUV"))
        XCTAssertNil(tune.pipeline)
        XCTAssertTrue(tune.reason.contains("Save to file"))
    }

    func testTheWarningNamesEncryption() {
        XCTAssertEqual(StartProblem.noDecoder(satellite: "X", encryption: .no), "There's no decoder for X's signal.")
        XCTAssertTrue(StartProblem.noDecoder(satellite: "X", encryption: .yes).contains("encrypted"))
    }
}

final class TestIsolationTests: XCTestCase {
    func testTestsNeverMoveRealFolders() {
        XCTAssertTrue(AppFolders.isTesting)
    }
}

final class DeviceDetectionTests: XCTestCase {
    /// What the engine really printed with an RTL-SDR dongle plugged in, whose name never says "RTL-SDR".
    private let output = """
    [14:23:07] (I) Found devices (sources) :
    [14:23:07] (I) - File Source
    [14:23:07] (D)     - type : file
    [14:23:07] (D)     - id : 0
    [14:23:07] (I) - Realtek RTL2838UHIDIR #00000001
    [14:23:07] (D)     - type : rtlsdr
    [14:23:07] (D)     - id : 00000001
    [14:23:07] (I) - RTL-TCP
    [14:23:07] (D)     - type : rtltcp
    [14:23:07] (D)     - id : 0
    [14:23:07] (I) Found devices (sinks) :
    [14:23:07] (I) - Not A Source
    [14:23:07] (D)     - type : sink
    [14:23:07] (I) Done! Goodbye
    """

    func testFindsADongleByItsTypeNotItsName() {
        let found = DetectedDevice.parse(output)
        XCTAssertEqual(found.map(\.type), ["file", "rtlsdr", "rtltcp"])
        XCTAssertEqual(found.first { $0.type == "rtlsdr" }?.name, "Realtek RTL2838UHIDIR #00000001")
        XCTAssertTrue(DetectedDevice.parse("nothing here").isEmpty)
    }

    func testEveryHardwareSourceCanBeFound() {
        let known = Set(HardwareSignature.all.map(\.sourceID))
        for source in SDRCatalog.sources where source.kind == .usb && !HardwareSignature.foundByEngineOnly.contains(source.id) {
            XCTAssertTrue(known.contains(source.id), "\(source.id) has no USB signature")
        }
        for id in known { XCTAssertNotNil(SDRCatalog.source(id), "\(id) isn't a source") }
    }

    func testSignaturesDontContradictEachOther() {
        var seen = Set<String>()
        for s in HardwareSignature.all {
            XCTAssertTrue(seen.insert("\(s.vendor):\(s.product ?? 0)").inserted, "\(s.name) is listed twice")
        }
    }

    func testRecognisesRealDevices() {
        func id(_ v: UInt16, _ p: UInt16) -> String? { HardwareSignature.match(vendor: v, product: p)?.sourceID }
        XCTAssertEqual(id(0x0bda, 0x2838), "rtlsdr", "the dongle that started this")
        XCTAssertEqual(id(0x0bda, 0x2832), "rtlsdr")
        XCTAssertEqual(id(0x1f4d, 0xd803), "rtlsdr", "the last in librtlsdr's table")
        XCTAssertEqual(id(0x1d50, 0x6089), "hackrf")
        XCTAssertEqual(id(0x1d50, 0x60a1), "airspy")
        XCTAssertEqual(id(0x03eb, 0x800c), "airspyhf")
        XCTAssertEqual(id(0x38af, 0x0001), "hydrasdr")
        XCTAssertEqual(id(0x1df7, 0x3050), "sdrplay", "any model")
        XCTAssertEqual(id(0x2cf0, 0x5250), "bladerf")
        XCTAssertEqual(id(0x2500, 0x0020), "usrp")
        XCTAssertEqual(id(0x16d0, 0x132e), "fobos")
        XCTAssertEqual(id(0x15a2, 0x008c), "rfnm")
        XCTAssertEqual(id(0x0456, 0xb673), "plutosdr")
        XCTAssertNil(id(0x05ac, 0x8600), "an Apple keyboard isn't a radio")
        XCTAssertNil(id(0x1d50, 0x0001), "same vendor as HackRF, but something else")
    }

    func testTwoAlikeShowAsOneSourceWithACount() {
        let found = AttachedHardware.from(usb: [(0x0bda, 0x2838, "RTL2838UHIDIR"), (0x0bda, 0x2832, nil), (0x05ac, 0x8600, "Keyboard")])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "RTL-SDR (RTL2838UHIDIR) × 2")
    }

    func testTheEngineAddsWhatUSBCantSay() {
        let usb = [AttachedHardware(sourceID: "rtlsdr", name: "RTL2838UHIDIR")]
        let named = AttachedHardware.merge(usb: usb, probed: DetectedDevice.parse(output))
        XCTAssertEqual(named.map(\.sourceID), ["rtlsdr"], "RTL-TCP and File Source aren't hardware")
        XCTAssertEqual(named[0].name, "Realtek RTL2838UHIDIR #00000001")
        let aaronia = AttachedHardware.merge(usb: [], probed: [DetectedDevice(name: "Spectran V6", type: "aaronia")])
        XCTAssertEqual(aaronia.map(\.sourceID), ["aaronia"])
        let hydra = AttachedHardware.merge(usb: [AttachedHardware(sourceID: "airspy", name: "Airspy")], probed: [DetectedDevice(name: "HydraSDR RFOne", type: "hydrasdr")])
        XCTAssertEqual(hydra.map(\.sourceID), ["hydrasdr"], "an old HydraSDR reports Airspy's numbers")
    }

    func testASingleDeviceIsChosenAndAChoiceInTheMenuStays() {
        let rtl = AttachedHardware(sourceID: "rtlsdr", name: "x"), hackrf = AttachedHardware(sourceID: "hackrf", name: "y")
        func use(_ current: String, _ old: [AttachedHardware], _ new: [AttachedHardware], first: Bool = false) -> String? {
            AttachedHardware.sourceToUse(current: current, old: old, new: new, firstLook: first)
        }
        XCTAssertEqual(use("spyserver", [], [rtl], first: true), "rtlsdr", "already plugged in at launch")
        XCTAssertEqual(use("spyserver", [], [rtl]), "rtlsdr", "plugged in later")
        XCTAssertNil(use("spyserver", [rtl], [rtl]), "picked a public station while it's plugged in, and nothing changed")
        XCTAssertNil(use("rtlsdr", [rtl], [rtl, hackrf]), "two now, so it stays on the one in use")
        XCTAssertNil(use("spyserver", [], [rtl, hackrf], first: true), "two, so that's your choice")
        XCTAssertEqual(use("rtlsdr", [rtl], []), SDRCatalog.sources[0].id, "pulled out")
        XCTAssertEqual(use("rtlsdr", [rtl, hackrf], [hackrf]), "hackrf", "only one left")
        XCTAssertNil(use("spyserver", [rtl], []), "something unused was pulled out")
    }

    @MainActor func testHardwareInTheMenuIsOnlyWhatsPluggedIn() {
        func hardware(_ a: [AttachedHardware]) -> [String] { SourceMenu.sections(attached: a).first { $0.title == "Hardware" }?.entries.map(\.title) ?? ["missing"] }
        XCTAssertEqual(hardware([]), [])
        XCTAssertEqual(hardware([AttachedHardware(sourceID: "rtlsdr", name: "RTL2838UHIDIR")]), ["RTL-SDR (RTL2838UHIDIR)"])
        let others = SourceMenu.sections(attached: []).filter { $0.title != "Hardware" }.flatMap(\.entries).map(\.id)
        XCTAssertTrue(others.contains("spyserver") && others.contains("rtltcp"), "public and network sources are always there")
        XCTAssertFalse(others.contains("rtlsdr"))
    }
}

final class LocationFinderTests: XCTestCase {
    func testReadsBothServicesReplies() throws {
        let ipwho = #"{"success":true,"latitude":48.85,"longitude":2.35,"city":"Paris","region":"Ile-de-France","country":"France","country_code":"FR"}"#
        let a = try XCTUnwrap(IPLocation.parse(Data(ipwho.utf8)))
        XCTAssertEqual(a.name, "Paris, Ile-de-France, France")
        XCTAssertEqual(a.iso, "fr")
        XCTAssertEqual(a.method, .internetAddress)
        let ipapi = #"{"latitude":35.0,"longitude":139.0,"city":"Tokyo","region":"Tokyo","country":"JP","country_name":"Japan","country_code":"JP"}"#
        XCTAssertEqual(try XCTUnwrap(IPLocation.parse(Data(ipapi.utf8))).name, "Tokyo, Japan")
    }

    func testIgnoresRepliesThatDontKnow() {
        for bad in [#"{"success":false,"message":"limit"}"#, #"{"error":true,"reason":"RateLimited"}"#,
                    #"{"latitude":0,"longitude":0}"#, #"{"latitude":120,"longitude":0}"#, "not json"] {
            XCTAssertNil(IPLocation.parse(Data(bad.utf8)), bad)
        }
    }

    func testNotesSayHowItWasFound() {
        XCTAssertEqual(LocationNote.within(64), "within about 60 m")
        XCTAssertEqual(LocationNote.within(2400), "within about 2 km")
        XCTAssertFalse(LocationNote.wifi(accuracy: 65).isWarning)
        XCTAssertFalse(LocationNote.wifi(accuracy: 65).offersGPSScan)
        XCTAssertTrue(LocationNote.internetAddress(wifi: .failed).offersGPSScan, "approximate, so a better answer is on offer")
        XCTAssertFalse(LocationNote.notFound.offersGPSScan)
        XCTAssertTrue(LocationNote.internetAddress(wifi: .notAllowed).text.contains("System Settings"))
        XCTAssertFalse(LocationNote.internetAddress(wifi: .failed).text.contains("System Settings"))
    }
}

final class KaitaiDecoderTests: XCTestCase {
    private let sample = """
    meta:
      id: sample
      endian: be
    doc: |
      :field kind: kind
      :field volts: body.volts
      :field second: body.readings.1
      :field flag: body.flag
      :field call: body.call
      :field missing: body.never
    seq:
      - id: kind
        type: u1
      - id: body
        type:
          switch-on: kind
          cases:
            1: telemetry
            _: other
    types:
      other:
        seq:
          - id: rest
            size-eos: true
      telemetry:
        seq:
          - id: raw_volts
            type: u2le
          - id: flag
            type: b1
          - id: pad
            type: b7
          - id: readings
            type: s1
            repeat: expr
            repeat-expr: 2
          - id: call
            size: 2
            type: str
            encoding: ASCII
          - id: never
            type: u1
            if: _parent.kind == 9
        instances:
          volts:
            value: "raw_volts * 0.5 + (flag ? 1 : 0)"
    """

    func testReadsNamedValuesFromAFrame() throws {
        let d = try KaitaiDecoder(yaml: sample)
        let out = try XCTUnwrap(d.decode([1, 0x10, 0x00, 0x80, 0x01, 0xFE, 0x41, 0x42]))
        let v = Dictionary(out, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(v["kind"], "1")
        XCTAssertEqual(v["volts"], "9")
        XCTAssertEqual(v["second"], "-2")
        XCTAssertEqual(v["flag"], "true")
        XCTAssertEqual(v["call"], "AB")
        XCTAssertNil(v["missing"])
    }

    func testEnumValuesReadAsWords() throws {
        let yaml = """
        meta: {id: x, endian: be}
        doc: |
          :field mode: mode
          :field twice: twice
          :field on: on_flag
        seq:
          - id: mode
            type: u1
            enum: modes
          - id: on_flag
            type: b1
            enum: switch
        instances:
          twice: {value: "mode.to_i * 2"}
        enums:
          modes: {2: safe}
          switch: {0: "off", 1: "on"}
        """
        let v = Dictionary(try XCTUnwrap(KaitaiDecoder(yaml: yaml).decode([2, 0x80])), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(v["mode"], "safe")
        XCTAssertEqual(v["twice"], "4")
        XCTAssertEqual(v["on"], "on")
    }

    func testAShortFrameIsNotReadAsAnything() throws {
        XCTAssertNil(try KaitaiDecoder(yaml: sample).decode([1, 0x10]))
    }

    func testABadDefinitionCannotHangTheApp() throws {
        let loop = """
        meta: {id: loop}
        doc: |
          :field a: a
        instances:
          a:
            value: b + 1
          b:
            value: a + 1
        """
        let endless = """
        meta: {id: endless}
        seq:
          - id: t
            type: t
        types:
          t:
            seq:
              - id: t
                type: t
        """
        XCTAssertEqual(try KaitaiDecoder(yaml: loop).decode([])?.count, 0)
        XCTAssertNil(try KaitaiDecoder(yaml: endless).decode([1, 2, 3]))
    }

    func testExpressionsFollowTheLanguage() throws {
        let yaml = """
        meta: {id: x}
        doc: |
          :field floor: floor
          :field mod: mod
          :field hex: hex
          :field sub: sub
          :field pick: pick
        instances:
          floor: {value: -7 / 2}
          mod: {value: -7 % 3}
          hex: {value: "'ff'.to_i(16)"}
          sub: {value: "'abcdef'.substring(1, 3)"}
          pick: {value: "1 + 1 == 2 and not false ? [4, 5][1] : 0"}
        """
        let v = Dictionary(try XCTUnwrap(KaitaiDecoder(yaml: yaml).decode([])), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(v["floor"], "-4")
        XCTAssertEqual(v["mod"], "2")
        XCTAssertEqual(v["hex"], "255")
        XCTAssertEqual(v["sub"], "bc")
        XCTAssertEqual(v["pick"], "5")
    }

    func testAscii85MatchesPython() throws {
        // Python: base64.a85encode(b"Hello") == b"87cURDZ"
        let encoded = KaitaiDecoder.ascii85Encode(Array("Hello".utf8))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "87cURDZ")
        XCTAssertEqual(try KaitaiDecoder.ascii85Decode(encoded), Array("Hello".utf8))
    }

    func testAssignmentsAndNamesFromSatNOGS() throws {
        let json = #"[{"norad_cat_id":24278,"telemetries":[{"decoder":"fo29"},{"decoder":"fo29"},{"decoder":""}]},{"norad_cat_id":1,"telemetries":[]},{"norad_cat_id":null}]"#
        XCTAssertEqual(SatNOGSDecoderFiles.assignments(in: Data(json.utf8)), [24278: ["fo29"]])
        XCTAssertTrue(SatNOGSDecoderFiles.isDefinitionName("fo29.ksy"))
        XCTAssertFalse(SatNOGSDecoderFiles.isDefinitionName("../fo29.ksy"))
        XCTAssertFalse(SatNOGSDecoderFiles.isDefinitionName("run.sh"))
        XCTAssertNil(SatNOGSDecoderFiles.latestCommit(in: Data(#"[{"id":"../../etc"}]"#.utf8)))
        XCTAssertTrue(DecodedTelemetry.isAddressField("src_callsign"))
        XCTAssertFalse(DecodedTelemetry.isAddressField("battery_voltage"))
    }
}

/// Runs when pointed at a downloaded copy of the SatNOGS definitions and their published test frames.
final class SatNOGSDecoderConformanceTests: XCTestCase {
    private struct Case: Decodable {
        struct Valid: Decodable { let frame: String; let expected: [String: Expected] }
        enum Expected: Decodable {
            case text(String), number(Double)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let n = try? c.decode(Double.self) { self = .number(n) } else if let b = try? c.decode(Bool.self) { self = .number(b ? 1 : 0) } else { self = .text(try c.decode(String.self)) }
            }
        }
        let dut: String
        let valid: [Valid]
        let invalid: [String]
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[a...hex.index(after: a)], radix: 16)!
        }
    }

    func testAgainstPublishedFrames() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SATNOGS_DECODERS_DIR"], let casesFile = env["SATNOGS_DECODER_CASES"] else { throw XCTSkip("Not pointed at a copy of the definitions") }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: casesFile)))
        var good = 0, bad = 0
        for c in cases {
            let d = try KaitaiDecoder(yaml: String(contentsOfFile: "\(dir)/ksy/\(c.dut).ksy", encoding: .utf8))
            for v in c.valid {
                let fields = Dictionary(d.decode(bytes(v.frame)) ?? [], uniquingKeysWith: { a, _ in a })
                for (name, expected) in v.expected {
                    let got = fields[name]
                    var same = false
                    switch expected {
                    case .text(let t): same = got == t.trimmingCharacters(in: .whitespacesAndNewlines) || (got == nil && t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    case .number(let n):
                        if let g = got.flatMap({ Double($0) }) { same = abs(g - n) <= max(abs(n) * 0.001, 1e-6) }
                        else if got == "true" { same = n == 1 } else if got == "false" { same = n == 0 }
                    }
                    if same { good += 1 } else { bad += 1; if bad < 30 { print("MISMATCH \(c.dut).\(name): got \(got ?? "nil") expected \(expected)") } }
                }
            }
            // A corrupt frame may still give the values that aren't affected, but never all of them.
            let complete = c.valid.map(\.expected.count).max() ?? .max
            for i in c.invalid where (d.decode(bytes(i))?.count ?? 0) >= complete { print("ACCEPTED INVALID \(c.dut) \(i)"); bad += 1 }
        }
        print("CONFORMANCE good=\(good) bad=\(bad)")
        XCTAssertEqual(bad, 0)
    }

    func testEveryDefinitionLoads() throws {
        guard let dir = ProcessInfo.processInfo.environment["SATNOGS_DECODERS_DIR"] else { throw XCTSkip("Not pointed at a copy of the definitions") }
        let files = try FileManager.default.contentsOfDirectory(atPath: "\(dir)/ksy").filter { $0.hasSuffix(".ksy") }
        var failed: [String] = []
        var noFields: [String] = []
        for f in files {
            do {
                let d = try KaitaiDecoder(yaml: String(contentsOfFile: "\(dir)/ksy/\(f)", encoding: .utf8))
                if d.fields.isEmpty { noFields.append(f) }
            } catch { failed.append("\(f): \(error)") }
        }
        print("LOADED \(files.count - failed.count)/\(files.count); no fields: \(noFields)")
        XCTAssertEqual(failed, [])
    }
}

final class PassAndLogTests: XCTestCase {
    func testGridSquares() {
        let c = Maidenhead.coordinates("FN31")!
        XCTAssertEqual(c.lat, 41.5, accuracy: 0.01); XCTAssertEqual(c.lon, -73, accuracy: 0.01)
        let fine = Maidenhead.coordinates("jo62qm")!
        XCTAssertEqual(Maidenhead.locator(lat: fine.lat, lon: fine.lon), "JO62")
        XCTAssertEqual(fine.lat, 52.52, accuracy: 0.03); XCTAssertEqual(fine.lon, 13.375, accuracy: 0.05)
        for bad in ["", "FN3", "ZZ99", "FN3X", "FN31ZZ", "12AB"] { XCTAssertNil(Maidenhead.coordinates(bad), bad) }
    }

    func testADIFRecord() {
        let c = ADIF.Contact(date: Date(timeIntervalSince1970: 1_767_323_045), call: "w1aw", grid: "fn31", sent: "59", received: "57",
                             satellite: "ISS (ZARYA)", mode: "FM voice", uplinkHz: 145_990_000, downlinkHz: 437_800_000, myCall: "N0CALL", myGrid: "MK82")
        let r = ADIF.record(c)
        for part in ["<QSO_DATE:8>20260102", "<TIME_ON:6>030405", "<CALL:4>W1AW", "<MODE:2>FM", "<BAND:2>2m", "<BAND_RX:4>70cm",
                     "<FREQ:10>145.990000", "<GRIDSQUARE:4>FN31", "<PROP_MODE:3>SAT", "<SAT_NAME:11>ISS (ZARYA)", "<EOR>"] {
            XCTAssertTrue(r.contains(part), part)
        }
        XCTAssertFalse(r.contains("SUBMODE"))
        XCTAssertEqual(ADIF.mode("FT4").submode, "FT4")
        XCTAssertEqual(ADIF.mode("SSB voice").mode, "SSB")
        XCTAssertNil(ADIF.band(100e6))
    }

    func testADIFFileGrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("log.adi")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c = ADIF.Contact(date: Date(), call: "W1AW", grid: "", sent: "59", received: "59", satellite: "X", mode: "CW", uplinkHz: nil, downlinkHz: nil, myCall: "N0CALL", myGrid: "")
        try ADIF.append(c, to: url); try ADIF.append(c, to: url)
        XCTAssertEqual(ADIF.count(in: url), 2)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("Vessel contact log"))
    }

    func testAnnouncementWording() {
        let p = SatPass(aos: Date(), los: Date().addingTimeInterval(600), peak: Date(), maxElevation: 41.6, track: [])
        XCTAssertEqual(PassPlanner.message(name: "ISS (ZARYA)", pass: p, minutes: 2), "ISS , ZARYA rises in 2 minutes, reaching 42 degrees.")
        XCTAssertEqual(PassPlanner.message(name: "AO-91", pass: p, minutes: 1), "AO-91 rises in 1 minute, reaching 42 degrees.")
        XCTAssertEqual(PassPlanner.message(name: "AO-91", pass: p, minutes: 0), "AO-91 is rising now, reaching 42 degrees.")
    }
}

final class WaterfallLabelTests: XCTestCase {
    func testRowsNeverOverlap() {
        let rows = WaterfallLabels.rows(centres: [100, 110, 120, 400], widths: [60, 60, 60, 60], maxRows: 2)
        XCTAssertEqual(rows[0], 0); XCTAssertEqual(rows[1], 1)
        XCTAssertNil(rows[2], "no room left, so it keeps its tick but not its name")
        XCTAssertEqual(rows[3], 0)
    }

    func testDopplerDecidesWhatIsInTheSpan() {
        let t = Transmitter(description: "x", downlinkHz: 437_000_000, mode: "FM", active: true, baud: nil)
        // Approaching at 7 km/s lifts it about 10 kHz.
        let up = WaterfallLabels.visible(transmitters: [t], rangeRate: -7, centre: 437_010_000, span: 6_000)
        XCTAssertEqual(up.first?.hz ?? 0, 437_010_204, accuracy: 10)
        XCTAssertTrue(WaterfallLabels.visible(transmitters: [t], rangeRate: 7, centre: 437_010_000, span: 6_000).isEmpty)
        let dead = Transmitter(description: "x", downlinkHz: 437_000_000, mode: "FM", active: false, baud: nil)
        XCTAssertTrue(WaterfallLabels.visible(transmitters: [dead], rangeRate: 0, centre: 437e6, span: 1e6).isEmpty)
    }
}

final class PassScheduleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func entry(_ norad: Int, _ start: TimeInterval, _ length: TimeInterval) -> ScheduledPass {
        ScheduledPass(norad: norad, name: "S\(norad)", pass: SatPass(aos: t0 + start, los: t0 + start + length, peak: t0 + start, maxElevation: 40, track: []))
    }

    func testPriorityDecidesBetweenOverlappingPasses() {
        let a = entry(1, 0, 600), b = entry(2, 100, 600)
        XCTAssertEqual(PassSchedule.choose([a, b], now: t0 + 200, priority: [2, 1], current: nil).active, b)
        XCTAssertEqual(PassSchedule.choose([a, b], now: t0 + 200, priority: [1, 2], current: nil).active, a)
    }

    func testAPassInProgressIsNotCutShort() {
        let a = entry(1, 0, 600), b = entry(2, 100, 600)
        XCTAssertEqual(PassSchedule.choose([a, b], now: t0 + 200, priority: [2, 1], current: a).active, a)
        XCTAssertEqual(PassSchedule.choose([a, b], now: t0 + 650, priority: [2, 1], current: a).active, b, "moves on once it sets")
    }

    func testNextAndTarget() {
        let a = entry(1, 0, 600), c = entry(3, 5000, 600)
        let quiet = PassSchedule.choose([a, c], now: t0 + 700, priority: [1, 3], current: nil)
        XCTAssertNil(quiet.active); XCTAssertEqual(quiet.next, c)
        XCTAssertEqual(PassSchedule.target(active: nil, next: c, lastEnded: a, now: t0 + 610), 1, "held briefly after it sets")
        XCTAssertEqual(PassSchedule.target(active: nil, next: c, lastEnded: a, now: t0 + 640), 3, "then tuned ahead to the next")
        XCTAssertEqual(PassSchedule.target(active: a, next: c, lastEnded: nil, now: t0 + 10), 1)
        XCTAssertNil(PassSchedule.target(active: nil, next: nil, lastEnded: nil, now: t0))
    }
}

final class RotatorPathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func track(_ pts: [(Double, Double)]) -> [SatPass.Point] { pts.map { SatPass.Point(az: $0.0, el: $0.1) } }
    /// Whether a rotator position points at the given spot in the sky.
    private func points(_ p: RotatorPath.Position, at az: Double, _ el: Double) -> Bool {
        let (a, e) = p.el > 90 ? (p.az + 180, 180 - p.el) : (p.az, p.el)
        let d = (a - az).truncatingRemainder(dividingBy: 360)
        return abs(e - el) < 1e-6 && (abs(d) < 1e-6 || abs(abs(d) - 360) < 1e-6)
    }

    func testCrossingNorthUsesTheOverlap() {
        // Moving east to west through north: 80° down to 330°.
        var north: [(Double, Double)] = []
        for i in 0...20 {
            let az: Double = 80 - Double(i) * 5.5
            north.append((az < 0 ? az + 360 : az, 20))
        }
        let t = track(north)
        let wide = RotatorPath.plan(track: t, aos: t0, los: t0 + 600, limits: .init(azMax: 450), from: nil)!
        XCTAssertEqual(wide.points.first?.az ?? 0, 440, accuracy: 0.01, "starts in the overlap so it never has to unwind")
        XCTAssertLessThan(wide.largestStep, 6)
        XCTAssertEqual(wide.downtime, 0, accuracy: 0.01)
        let plain = RotatorPath.plan(track: t, aos: t0, los: t0 + 600, limits: .init(), from: nil)!
        XCTAssertGreaterThan(plain.largestStep, 300, "without the overlap one full swing can't be avoided")
        XCTAssertGreaterThan(plain.downtime, 20)
    }

    func testOverheadPassTiltsOverTheTop() {
        // Nearly straight overhead: azimuth jumps from south to north in a few seconds.
        var pts: [(Double, Double)] = []
        for i in 0...20 {
            let x: Double = Double(i) / 20
            let el: Double = 90 - abs(x - 0.5) * 176
            pts.append((x < 0.5 ? 180 : 0, el))
        }
        let t = track(pts)
        let flip = RotatorPath.plan(track: t, aos: t0, los: t0 + 600, limits: .init(elMax: 180), from: nil)!
        XCTAssertLessThan(flip.largestStep, 1, "azimuth stays put while elevation carries on past 90°")
        XCTAssertEqual(flip.downtime, 0, accuracy: 0.01)
        let plain = RotatorPath.plan(track: t, aos: t0, los: t0 + 600, limits: .init(), from: nil)!
        XCTAssertEqual(plain.largestStep, 180, accuracy: 0.01)
    }

    func testEveryPointStaysInLimitsAndOnTarget() {
        var sweep: [(Double, Double)] = []
        for i in 0...30 {
            let az: Double = (300 + Double(i) * 9).truncatingRemainder(dividingBy: 360)
            let el: Double = 5 + Double(15 - abs(15 - i)) * 5
            sweep.append((az, el))
        }
        let t = track(sweep)
        for limits in [RotatorPath.Limits(), .init(azMax: 450), .init(elMax: 180), .init(azMax: 450, elMax: 180)] {
            let p = RotatorPath.plan(track: t, aos: t0, los: t0 + 700, limits: limits, from: nil)!
            for (pos, want) in zip(p.points, t) {
                XCTAssertTrue(pos.az >= limits.azMin && pos.az <= limits.azMax && pos.el >= 0 && pos.el <= limits.elMax)
                XCTAssertTrue(points(pos, at: want.az, want.el), "\(pos) for \(want)")
            }
        }
    }

    func testStartsNearestTheAntennaAndInterpolates() {
        let t = track([(30, 10), (40, 20), (50, 10)])
        let low = RotatorPath.plan(track: t, aos: t0, los: t0 + 300, limits: .init(azMax: 450), from: .init(az: 20, el: 0))!
        let high = RotatorPath.plan(track: t, aos: t0, los: t0 + 300, limits: .init(azMax: 450), from: .init(az: 400, el: 0))!
        XCTAssertEqual(low.points[0].az, 30); XCTAssertEqual(high.points[0].az, 390)
        XCTAssertEqual(low.position(at: t0 + 75)?.az ?? 0, 35, accuracy: 0.01)
        XCTAssertNil(low.position(at: t0 - 1)); XCTAssertNil(low.position(at: t0 + 301))
    }
}

final class FrequencyCorrectionTests: XCTestCase {
    func testDialCancelsTheClockError() {
        // A clock 10 ppm fast lands 4.37 kHz high at 437 MHz, so ask for that much less.
        XCTAssertEqual(FrequencyCorrection.error(at: 437e6, ppm: 10), 4370, accuracy: 0.01)
        let dial = FrequencyCorrection.dial(437e6, ppm: 10)
        XCTAssertEqual(dial * (1 + 10e-6), 437e6, accuracy: 0.01)
        XCTAssertEqual(FrequencyCorrection.dial(437e6, ppm: 0), 437e6)
    }

    func testDriversThatCorrectThemselvesAreLeftAlone() {
        XCTAssertEqual(FrequencyCorrection.requested(437e6, source: "rtlsdr", ppm: 10), 437e6)
        XCTAssertEqual(FrequencyCorrection.arguments(source: "rtlsdr", ppm: 3), ["--ppm_correction", "3"])
        // 2.4 ppm: the driver takes 2, and the other 0.4 comes off the dial.
        XCTAssertEqual(FrequencyCorrection.arguments(source: "rtltcp", ppm: 2.4), ["--ppm_correction", "2"])
        XCTAssertEqual(FrequencyCorrection.requested(437e6, source: "rtltcp", ppm: 2.4), 437e6 / (1 + 0.4e-6), accuracy: 0.01)
        XCTAssertLessThan(FrequencyCorrection.requested(437e6, source: "airspy", ppm: 10), 437e6)
        XCTAssertEqual(FrequencyCorrection.arguments(source: "airspy", ppm: 10), [])
        XCTAssertEqual(FrequencyCorrection.arguments(source: "rtlsdr", ppm: 0), [])
    }

    func testOffsetKeyIsPerSignal() {
        XCTAssertEqual(FrequencyCorrection.key(norad: 25544, hz: 145_800_400), "25544-145800")
        XCTAssertNotEqual(FrequencyCorrection.key(norad: 25544, hz: 145_800_000), FrequencyCorrection.key(norad: 25544, hz: 437_800_000))
    }
}

final class FTDecoderTests: XCTestCase {
    private func slot(_ text: String, ft4: Bool) -> [Float] {
        let tone = AudioSignals.ftx(text: text, ft4: ft4)!
        var audio = [Float](repeating: 0, count: 24_000) + tone
        audio += [Float](repeating: 0, count: max(0, Int((ft4 ? 7.5 : 15) * 48_000) - audio.count))
        return audio
    }

    /// What this app sends must be what a decoder reads back, for both modes.
    func testOwnSignalsDecode() {
        for ft4 in [false, true] {
            for text in ["CQ K1ABC FN31", "W1AW K1ABC R-12", "W1AW K1ABC 73"] {
                let found = FTDecoder.decode(slot(text, ft4: ft4), rate: 48_000, ft4: ft4)
                XCTAssertEqual(found.map(\.text), [text], "\(ft4 ? "FT4" : "FT8")")
                XCTAssertEqual(found.first?.audioHz ?? 0, 1500, accuracy: 8)
                XCTAssertEqual(found.first?.offset ?? 0, 0.5, accuracy: 0.2)
            }
        }
    }

    /// A callsign outside the standard format is sent as a hash, and read back from the table of calls seen.
    func testNonStandardCallsignComesBackFromTheHashTable() {
        let found = FTDecoder.decode(slot("CQ N0CALL FN31", ft4: false), rate: 48_000, ft4: false)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.text.contains("N0CALL") == true, found.first?.text ?? "nothing")
    }

    func testSilenceAndNoiseDecodeToNothing() {
        XCTAssertTrue(FTDecoder.decode([Float](repeating: 0, count: 48_000 * 15), rate: 48_000, ft4: false).isEmpty)
        var g = SystemRandomNumberGenerator()
        let noise = (0..<(12_000 * 15)).map { _ in Float.random(in: -0.5...0.5, using: &g) }
        XCTAssertTrue(FTDecoder.decode(noise, rate: 12_000, ft4: false).isEmpty)
        XCTAssertTrue(FTDecoder.decode(noise, rate: 12_000, ft4: true).isEmpty)
    }

    func testDecodesThroughNoise() {
        let tone = AudioSignals.ftx(text: "CQ K1ABC FN31", ft4: false)!
        var g = SystemRandomNumberGenerator()
        var audio = [Float](repeating: 0, count: 48_000 * 15)
        for i in audio.indices { audio[i] = Float.random(in: -1...1, using: &g) }
        for (i, s) in tone.enumerated() { audio[24_000 + i] += s * 0.3 }
        XCTAssertEqual(FTDecoder.decode(audio, rate: 48_000, ft4: false).map(\.text), ["CQ K1ABC FN31"])
    }
}

final class SSBReceiverTests: XCTestCase {
    /// Strength of one audio frequency, by correlation.
    private func level(_ a: [Float], _ hz: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, s) in a.enumerated().dropFirst(a.count / 4) {
            let w = 2 * Double.pi * hz * Double(i) / rate
            re += Double(s) * cos(w); im += Double(s) * sin(w)
        }
        return (re * re + im * im).squareRoot() / Double(a.count)
    }

    private func tone(_ hz: Double, rate: Double, seconds: Double) -> [Float] {
        var iq: [Float] = []
        for i in 0..<Int(rate * seconds) {
            let w = 2 * Double.pi * hz * Double(i) / rate
            iq.append(Float(cos(w))); iq.append(Float(sin(w)))
        }
        return iq
    }

    func testKeepsOneSidebandAndRejectsTheOther() {
        let rate = 240_000.0
        var usb = SSBDemod(inputRate: rate, usb: true)
        let above = usb.process(tone(1000, rate: rate, seconds: 1))
        XCTAssertGreaterThan(level(above, 1000, rate: usb.outputRate), 0.2, "1 kHz above the carrier is heard as 1 kHz")
        var usb2 = SSBDemod(inputRate: rate, usb: true)
        let below = usb2.process(tone(-1000, rate: rate, seconds: 1))
        XCTAssertLessThan(level(below, 1000, rate: usb2.outputRate), 0.005, "the other sideband is rejected")
        var lsb = SSBDemod(inputRate: rate, usb: false)
        XCTAssertGreaterThan(level(lsb.process(tone(-1000, rate: rate, seconds: 1)), 1000, rate: lsb.outputRate), 0.2)
    }

    func testOffsetFollowsTheCarrier() {
        let rate = 240_000.0
        var d = SSBDemod(inputRate: rate, usb: true)
        d.offsetHz = 7000
        XCTAssertGreaterThan(level(d.process(tone(8000, rate: rate, seconds: 1)), 1000, rate: d.outputRate), 0.2)
    }

    /// The whole receive path: our FT4 signal, placed on a carrier 6 kHz off centre, comes back as text.
    func testFT4ThroughTheReceiver() {
        let audio = AudioSignals.ftx(text: "CQ K1ABC FN31", ft4: true)!
        // A real signal sent as I only has both sidebands, and the receiver must pick the upper one.
        var iq: [Float] = []
        let padded = [Float](repeating: 0, count: 24_000) + audio + [Float](repeating: 0, count: 120_000)
        for (i, s) in padded.enumerated() {
            let w = 2 * Double.pi * 6000 * Double(i) / 48_000
            iq.append(s * Float(cos(w))); iq.append(s * Float(sin(w)))
        }
        var d = SSBDemod(inputRate: 48_000, usb: true)
        d.offsetHz = 6000
        let out = d.process(iq)
        let found = FTDecoder.decode(out, rate: Int(d.outputRate), ft4: true)
        XCTAssertEqual(found.map(\.text), ["CQ K1ABC FN31"])
        XCTAssertEqual(found.first?.audioHz ?? 0, 1500, accuracy: 10)
    }

    func testSlotWindow() {
        // 20 s held at 12 kHz, 2 s after a 15 s boundary: the slot is the 15 s that ended 2 s ago.
        XCTAssertEqual(FTMonitor.slotWindow(count: 240_000, rate: 12_000, sinceBoundary: 2, slot: 15), 36_000..<216_000)
        XCTAssertEqual(FTMonitor.slotWindow(count: 240_000, rate: 12_000, sinceBoundary: 2, slot: 15, delay: 0.5), 42_000..<222_000)
        XCTAssertNil(FTMonitor.slotWindow(count: 60_000, rate: 12_000, sinceBoundary: 2, slot: 15), "not enough audio yet")
    }
}

final class JE9PELTests: XCTestCase {
    private let sample = """
    239Alferov;64881;;436.270/10473.350;;9k6 GFSK/DVB-S2 QPSK;RS61S;active
    ISS;25544;;145.800;;SSTV;;active
    ISS;25544;145.825;145.825;;1k2 AFSK;RS0ISS ARISS;active
    3CAT-3;;;;;;;to be launched
    OLDSAT;11111;;437.000;;9k6 FSK;OLD1;re-entered
    BEACON;22222;;;435.500;CW;BCN1;active
    FO-29;24278;145.900-146.000;435.800-435.900;435.795;SSB CW;8J1JCS;active
    """

    func testParsesRowsAndSkipsThoseWithoutACatalogueNumber() {
        let t = JE9PEL.parse(sample)
        XCTAssertEqual(t.keys.sorted(), [11111, 22222, 24278, 25544, 64881])
        XCTAssertEqual(t[64881]?.first?.downlinksHz, [436.27e6, 10473.35e6])
        XCTAssertEqual(t[25544]?.count, 2)
        XCTAssertEqual(JE9PEL.callsign(t[25544]!), "RS0ISS ARISS", "the first row has none, so the second is used")
        XCTAssertEqual(t[22222]?.first?.downlinksHz, [435.5e6], "falls back to the beacon column")
        XCTAssertEqual(t[24278]?.first?.downlinksHz, [435.8e6, 435.9e6])
    }

    func testOnlyAddsWhatIsMissingAndNeverAnUplink() {
        let t = JE9PEL.parse(sample)
        let have = [Transmitter(description: "x", downlinkHz: 145_800_500, mode: "FM", active: true, baud: nil)]
        let extra = JE9PEL.extraTransmitters(t[25544]!, existing: have)
        XCTAssertEqual(extra.map(\.downlinkHz), [145.825e6], "145.800 is already there")
        XCTAssertTrue(extra.allSatisfy { $0.uplinkLowHz == nil && UplinkPolicy.make($0) == nil })
        XCTAssertTrue(JE9PEL.extraTransmitters(t[11111]!, existing: []).isEmpty, "a re-entered satellite adds nothing")
        XCTAssertEqual(JE9PEL.modeWord("9k6 GFSK/DVB-S2 QPSK"), "GFSK")
        XCTAssertEqual(JE9PEL.modeWord("1k2 AFSK"), "AFSK")
    }
}

@MainActor final class SatelliteGroupsTests: XCTestCase {
    func testGroupsPersistAndFilter() {
        let key = "test.groups.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let g = SatelliteGroups(key: key)
        XCTAssertTrue(g.create("FM birds")); XCTAssertFalse(g.create("FM birds")); XCTAssertFalse(g.create("  "))
        g.add(25544, to: "FM birds"); g.add(25544, to: "FM birds"); g.add(43017, to: "FM birds")
        XCTAssertEqual(g.group("FM birds")?.norads, [25544, 43017])
        XCTAssertNil(g.shownNorads)
        g.shown = "FM birds"
        XCTAssertEqual(g.shownNorads, [25544, 43017])
        XCTAssertEqual(SatelliteGroups(key: key).group("FM birds")?.norads, [25544, 43017], "saved across launches")
        g.remove(25544, from: "FM birds")
        XCTAssertEqual(g.shownNorads, [43017])
        g.delete("FM birds")
        XCTAssertNil(g.shown); XCTAssertNil(g.shownNorads)
    }

    func testFilterCountsAGroupAsActive() {
        var f = SatelliteFilter()
        XCTAssertFalse(f.isActive)
        f.onlyNorads = [1]
        XCTAssertEqual(f.activeCount, 1)
    }
}

final class SSDVTests: XCTestCase {
    /// A 320 by 240 test picture as a baseline JPEG.
    private func picture() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<240 {
            for x in 0..<320 {
                rep.setColor(NSColor(red: CGFloat(x) / 320, green: CGFloat(y) / 240, blue: (x / 40 + y / 40) % 2 == 0 ? 0.9 : 0.2, alpha: 1), atX: x, y: y)
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8, .progressive: false])!
    }

    private func size(_ jpeg: Data?) -> NSSize? {
        jpeg.flatMap { NSBitmapImageRep(data: $0) }.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
    }

    func testPictureSurvivesTheRoundTrip() {
        let packets = SSDVAssembler.encode(jpeg: picture(), callsign: "TEST1", imageID: 7)
        XCTAssertGreaterThan(packets.count, 5)
        let a = SSDVAssembler()
        var key: SSDVAssembler.Key?
        for p in packets { key = a.feed(p).first ?? key }
        XCTAssertEqual(key, SSDVAssembler.Key(callsign: "TEST1", imageID: 7))
        let pic = a.pictures[key!]!
        XCTAssertTrue(pic.isComplete)
        XCTAssertEqual(pic.total, packets.count)
        XCTAssertEqual(size(a.jpeg(key!)), NSSize(width: 320, height: 240))
        XCTAssertEqual(SSDVAssembler.fileName(key!), "ssdv_TEST1_7.jpg")
    }

    func testLostAndRepeatedPacketsStillGiveAPicture() {
        var packets = SSDVAssembler.encode(jpeg: picture(), callsign: "TEST1", imageID: 1)
        packets.remove(at: 3); packets.remove(at: 1)
        let a = SSDVAssembler()
        // Out of order and with one repeated, as on a real pass.
        for p in packets.reversed() + [packets[0]] { a.feed(p) }
        let key = SSDVAssembler.Key(callsign: "TEST1", imageID: 1)
        XCTAssertEqual(a.pictures[key]?.packets.count, packets.count, "a repeat isn't counted twice")
        XCTAssertFalse(a.pictures[key]!.isComplete)
        XCTAssertEqual(size(a.jpeg(key)), NSSize(width: 320, height: 240), "the gaps are left grey, not fatal")
    }

    func testPacketsAreFoundInsideOtherData() {
        let packets = SSDVAssembler.encode(jpeg: picture(), callsign: "TEST1", imageID: 2)
        var stream: [UInt8] = [0x00, 0x55, 0x66, 0x12, 0x55]   // junk that looks like a start
        stream += packets[0]
        stream += [0xAA, 0xBB]
        stream += Array(packets[1].dropFirst())                  // sent without its sync byte
        stream += [UInt8](repeating: 0x55, count: 300)
        let found = SSDVAssembler.packets(in: stream)
        XCTAssertEqual(found.map { Int($0.info.packet_id) }, [0, 1])
        XCTAssertEqual(found[1].packet, packets[1], "the sync byte is put back")
    }

    func testCorruptPacketsAreRejectedOrRepaired() {
        var p = SSDVAssembler.encode(jpeg: picture(), callsign: "TEST1", imageID: 3)[2]
        let original = p
        p[100] ^= 0xFF; p[120] ^= 0x0F
        let repaired = SSDVAssembler.packets(in: p)
        XCTAssertEqual(repaired.first?.packet, original, "a few wrong bytes are corrected by the packet's own error correction")
        for i in stride(from: 20, to: 250, by: 3) { p[i] ^= 0xA5 }
        XCTAssertTrue(SSDVAssembler.packets(in: p).isEmpty, "too damaged to trust, so it's dropped")
        XCTAssertTrue(SSDVAssembler.packets(in: [UInt8](repeating: 0, count: 1000)).isEmpty)
    }
}
