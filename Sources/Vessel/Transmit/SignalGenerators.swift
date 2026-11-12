import Foundation
import CFT8

/// AX.25 UI frames, as used by APRS.
enum AX25 {
    static func crc(_ bytes: [UInt8]) -> UInt16 {
        var fcs: UInt16 = 0xFFFF
        for b in bytes {
            var v = b
            for _ in 0..<8 {
                let bit = (fcs ^ UInt16(v)) & 1
                fcs >>= 1
                if bit == 1 { fcs ^= 0x8408 }
                v >>= 1
            }
        }
        return ~fcs
    }

    private static func address(_ call: String, last: Bool, command: Bool) -> [UInt8] {
        let parts = call.uppercased().split(separator: "-")
        let base = Array(String(parts.first ?? "").utf8.prefix(6))
        let padded = base + [UInt8](repeating: 0x20, count: 6 - base.count)
        let ssid = UInt8(parts.count > 1 ? Int(parts[1]) ?? 0 : 0) & 0x0F
        return padded.map { $0 << 1 } + [(command ? 0xE0 : 0x60) | (ssid << 1) | (last ? 1 : 0)]
    }

    static func uiFrame(source: String, destination: String, path: [String], info: String) -> [UInt8] {
        var f = address(destination, last: false, command: true)
        f += address(source, last: path.isEmpty, command: false)
        for (i, p) in path.enumerated() { f += address(p, last: i == path.count - 1, command: false) }
        f += [0x03, 0xF0] + Array(info.utf8)
        let fcs = crc(f)
        return f + [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
    }

    /// Flags, then the bit-stuffed frame sent least-significant bit first, then closing flags.
    static func bits(frame: [UInt8], preambleFlags: Int, trailingFlags: Int) -> [Bool] {
        func flag() -> [Bool] { (0..<8).map { (0x7E >> $0) & 1 == 1 } }
        var out: [Bool] = []
        for _ in 0..<preambleFlags { out += flag() }
        var ones = 0
        for byte in frame {
            for i in 0..<8 {
                let bit = (byte >> i) & 1 == 1
                out.append(bit)
                ones = bit ? ones + 1 : 0
                if ones == 5 { out.append(false); ones = 0 }
            }
        }
        for _ in 0..<trailingFlags { out += flag() }
        return out
    }
}

/// An APRS position report. It's public and stays online, so how exact it is should be a choice.
enum APRSPosition {
    enum Precision: String, CaseIterable, Identifiable {
        case exact = "Exact"
        case about2km = "About 2 km"
        case about20km = "About 20 km"
        var id: String { rawValue }
        /// APRS blurs a position by blanking its last digits.
        var blanks: Int {
            switch self {
            case .exact: 0
            case .about2km: 2
            case .about20km: 3
            }
        }
    }

    /// `degreeDigits` 2 for latitude, 3 for longitude.
    static func angle(_ value: Double, degreeDigits: Int, positive: Character, negative: Character, blanks: Int) -> String {
        let a = abs(value)
        var degrees = Int(a)
        var hundredths = Int(((a - Double(degrees)) * 6000).rounded())
        if hundredths >= 6000 { degrees += 1; hundredths = 0 }
        let minutes = String(format: "%02d.%02d", hundredths / 100, hundredths % 100)
        var chars = Array(String(format: "%0\(degreeDigits)d", degrees) + minutes)
        // Blanks count back from the last digit, stepping over the decimal point.
        var left = blanks, i = chars.count - 1
        while left > 0, i >= 0 {
            if chars[i] != "." { chars[i] = " "; left -= 1 }
            i -= 1
        }
        return String(chars) + String(value < 0 ? negative : positive)
    }

    /// "=" is a position with no timestamp. "/-" is the symbol for a home station.
    static func info(lat: Double, lon: Double, precision: Precision, comment: String) -> String {
        let la = angle(lat, degreeDigits: 2, positive: "N", negative: "S", blanks: precision.blanks)
        let lo = angle(lon, degreeDigits: 3, positive: "E", negative: "W", blanks: precision.blanks)
        return "=\(la)/\(lo)-\(comment.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

enum AudioSignals {
    static let sampleRate = 48_000.0

    /// Bell 202 AFSK at 1200 baud with NRZI coding, keeping phase continuous across tone changes.
    static func afsk(bits: [Bool], amplitude: Float = 0.7) -> [Float] {
        let perBit = sampleRate / 1200
        var out: [Float] = []
        out.reserveCapacity(Int(Double(bits.count) * perBit) + 1)
        var mark = true
        var phase = 0.0
        var emitted = 0.0
        for (i, bit) in bits.enumerated() {
            if !bit { mark.toggle() }
            let step = 2 * Double.pi * (mark ? 1200 : 2200) / sampleRate
            let target = Double(i + 1) * perBit
            while emitted < target {
                out.append(Float(sin(phase)) * amplitude)
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
                emitted += 1
            }
        }
        return out
    }

    static func aprs(source: String, path: [String], text: String) -> [Float] {
        aprsPacket(source: source, path: path, info: ">" + text)
    }

    static func aprsPacket(source: String, path: [String], info: String) -> [Float] {
        // APZ is the tocall block reserved for experimental software.
        let frame = AX25.uiFrame(source: source, destination: "APZODK", path: path, info: info)
        return afsk(bits: AX25.bits(frame: frame, preambleFlags: 45, trailingFlags: 4))
    }

    private static let morse: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....", "I": "..",
        "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
        "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....", "6": "-....", "7": "--...",
        "8": "---..", "9": "----.", "/": "-..-.", "?": "..--..", ".": ".-.-.-", ",": "--..--", "=": "-...-", "-": "-....-",
    ]

    /// Timing in dits: true is tone, false is silence.
    static func morseTiming(_ text: String) -> [(on: Bool, dits: Int)] {
        var out: [(Bool, Int)] = []
        for word in text.uppercased().split(whereSeparator: \.isWhitespace) {
            if !out.isEmpty { out.append((false, 7)) }
            var firstChar = true
            for ch in word {
                guard let code = morse[ch] else { continue }
                if !firstChar { out.append((false, 3)) }
                firstChar = false
                for (i, sym) in code.enumerated() {
                    if i > 0 { out.append((false, 1)) }
                    out.append((true, sym == "." ? 1 : 3))
                }
            }
        }
        return out
    }

    /// Tone-keyed CW with raised-cosine edges: hard edges would splatter across the transponder.
    static func cw(text: String, wpm: Double = 18, toneHz: Double = 700, amplitude: Float = 0.7) -> [Float] {
        let dit = 1.2 / wpm
        let ramp = Int(0.005 * sampleRate)
        var out: [Float] = []
        var phase = 0.0
        let step = 2 * Double.pi * toneHz / sampleRate
        for (on, dits) in morseTiming(text) {
            let n = Int(Double(dits) * dit * sampleRate)
            for i in 0..<n {
                var v: Float = 0
                if on {
                    var env = 1.0
                    if i < ramp { env = 0.5 * (1 - cos(.pi * Double(i) / Double(ramp))) }
                    if n - 1 - i < ramp { env = 0.5 * (1 - cos(.pi * Double(n - 1 - i) / Double(ramp))) }
                    v = Float(sin(phase) * env) * amplitude
                }
                out.append(v)
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }
        return out
    }

    // MARK: Packet

    /// AX.25 with no fixed digipeater format: the header carries the callsign, the body is plain text.
    static func packet1200(source: String, path: [String], text: String) -> [Float] {
        let frame = AX25.uiFrame(source: source, destination: "CQ", path: path, info: text)
        return afsk(bits: AX25.bits(frame: frame, preambleFlags: 45, trailingFlags: 4))
    }

    static func packet9600(source: String, path: [String], text: String) -> [Float] {
        let frame = AX25.uiFrame(source: source, destination: "CQ", path: path, info: text)
        // At 9600 baud the preamble also lets the receiver's descrambler settle: 300 ms of flags.
        return g3ruh(bits: AX25.bits(frame: frame, preambleFlags: 360, trailingFlags: 8))
    }

    /// G3RUH 9600 baud: NRZI, the x^17 + x^12 + 1 scrambler, then a raised-cosine baseband.
    /// This goes to the radio's data port, not its microphone input.
    static func g3ruh(bits: [Bool], amplitude: Float = 0.6) -> [Float] {
        var level = false
        var lfsr: UInt32 = 0
        var symbols: [Float] = []
        symbols.reserveCapacity(bits.count)
        for bit in bits {
            if !bit { level.toggle() }
            let x = (level ? UInt32(1) : 0) ^ ((lfsr >> 16) & 1) ^ ((lfsr >> 11) & 1)
            lfsr = (lfsr << 1) | x
            symbols.append(x == 1 ? 1 : -1)
        }
        let perBit = 5 // 48 kHz / 9600
        let span = 4 // symbols each side
        let alpha = 0.5
        var taps = [Float](repeating: 0, count: 2 * span * perBit + 1)
        for i in taps.indices {
            let t = Double(i - span * perBit) / Double(perBit)
            let denom = 1 - pow(2 * alpha * t, 2)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let shape = abs(denom) < 1e-6 ? .pi / 4 * sin(.pi / (2 * alpha)) / (.pi / (2 * alpha)) : cos(.pi * alpha * t) / denom
            taps[i] = Float(sinc * shape)
        }
        var out = [Float](repeating: 0, count: symbols.count * perBit + taps.count)
        for (n, s) in symbols.enumerated() {
            for (i, tap) in taps.enumerated() { out[n * perBit + i] += s * tap * amplitude }
        }
        return out
    }

    // MARK: PSK31

    /// Varicode from the PSK31 specification, checked against fldigi's table.
    static let varicode: [Character: String] = [
        "\n": "11101", "\r": "11111", " ": "1", "!": "111111111", "\"": "101011111", "#": "111110101", "$": "111011011",
        "%": "1011010101", "&": "1010111011", "'": "101111111", "(": "11111011", ")": "11110111", "*": "101101111",
        "+": "111011111", ",": "1110101", "-": "110101", ".": "1010111", "/": "110101111", "0": "10110111", "1": "10111101",
        "2": "11101101", "3": "11111111", "4": "101110111", "5": "101011011", "6": "101101011", "7": "110101101",
        "8": "110101011", "9": "110110111", ":": "11110101", ";": "110111101", "<": "111101101", "=": "1010101",
        ">": "111010111", "?": "1010101111", "@": "1010111101", "A": "1111101", "B": "11101011", "C": "10101101",
        "D": "10110101", "E": "1110111", "F": "11011011", "G": "11111101", "H": "101010101", "I": "1111111",
        "J": "111111101", "K": "101111101", "L": "11010111", "M": "10111011", "N": "11011101", "O": "10101011",
        "P": "11010101", "Q": "111011101", "R": "10101111", "S": "1101111", "T": "1101101", "U": "101010111",
        "V": "110110101", "W": "101011101", "X": "101110101", "Y": "101111011", "Z": "1010101101", "[": "111110111",
        "\\": "111101111", "]": "111111011", "^": "1010111111", "_": "101101101", "`": "1011011111", "a": "1011",
        "b": "1011111", "c": "101111", "d": "101101", "e": "11", "f": "111101", "g": "1011011", "h": "101011",
        "i": "1101", "j": "111101011", "k": "10111111", "l": "11011", "m": "111011", "n": "1111", "o": "111",
        "p": "111111", "q": "110111111", "r": "10101", "s": "10111", "t": "101", "u": "110111", "v": "1111011",
        "w": "1101011", "x": "11011111", "y": "1011101", "z": "111010101",
    ]

    /// BPSK at 31.25 baud: a 0 reverses phase through a cosine envelope, a 1 holds the carrier.
    static func psk31(text: String, toneHz: Double = 1000, amplitude: Float = 0.7) -> [Float] {
        var bits = [Bool](repeating: false, count: 32)
        for ch in text {
            guard let code = varicode[ch] else { continue }
            bits += code.map { $0 == "1" }
            bits += [false, false]
        }
        bits += [Bool](repeating: true, count: 24)
        let n = Int(sampleRate / 31.25)
        var out: [Float] = []
        out.reserveCapacity(n * bits.count)
        var sign = 1.0
        var phase = 0.0
        let step = 2 * Double.pi * toneHz / sampleRate
        for bit in bits {
            for i in 0..<n {
                let env = bit ? sign : sign * cos(.pi * Double(i) / Double(n))
                out.append(Float(env * sin(phase)) * amplitude)
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            if !bit { sign = -sign }
        }
        fade(&out)
        return out
    }

    private static func fade(_ s: inout [Float], seconds: Double = 0.01) {
        let r = min(Int(seconds * sampleRate), s.count / 2)
        for i in 0..<r {
            let g = Float(0.5 * (1 - cos(.pi * Double(i) / Double(r))))
            s[i] *= g
            s[s.count - 1 - i] *= g
        }
    }

    // MARK: RTTY

    private static let baudotLetters: [Character: UInt8] = [
        "A": 3, "B": 25, "C": 14, "D": 9, "E": 1, "F": 13, "G": 26, "H": 20, "I": 6, "J": 11, "K": 15, "L": 18, "M": 28,
        "N": 12, "O": 24, "P": 22, "Q": 23, "R": 10, "S": 5, "T": 16, "U": 7, "V": 30, "W": 19, "X": 29, "Y": 21, "Z": 17,
    ]
    private static let baudotFigures: [Character: UInt8] = [
        "1": 23, "2": 19, "3": 1, "4": 10, "5": 16, "6": 21, "7": 7, "8": 6, "9": 24, "0": 22,
        "-": 3, "?": 25, ":": 14, ".": 28, ",": 12, "/": 29, "(": 15, ")": 18,
    ]

    /// ITA2 codes, inserting shifts. Characters the alphabet doesn't have are dropped.
    static func baudot(_ text: String) -> [UInt8] {
        let ltrs: UInt8 = 31, figs: UInt8 = 27
        var out: [UInt8] = [ltrs, ltrs]
        var inFigures = false
        for ch in text.uppercased() {
            if ch == " " { out.append(4); continue }
            if ch == "\n" { out += [8, 2]; continue }
            if let c = baudotLetters[ch] {
                if inFigures { out.append(ltrs); inFigures = false }
                out.append(c)
            } else if let c = baudotFigures[ch] {
                if !inFigures { out.append(figs); inFigures = true }
                out.append(c)
            }
        }
        return out
    }

    /// 45.45 baud with 170 Hz shift and 1.5 stop bits. Mark must be the higher RF frequency, so
    /// the tones swap between USB and LSB.
    static func rtty(text: String, usb: Bool, amplitude: Float = 0.7) -> [Float] {
        let mark = usb ? 2295.0 : 2125.0, space = usb ? 2125.0 : 2295.0
        let bitLen = sampleRate / 45.45
        var out: [Float] = []
        var phase = 0.0
        var pending = 0.0
        func emit(_ f: Double, _ length: Double) {
            pending += length
            let n = Int(pending)
            pending -= Double(n)
            let step = 2 * Double.pi * f / sampleRate
            for _ in 0..<n {
                out.append(Float(sin(phase)) * amplitude)
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }
        emit(mark, bitLen * 15) // idle on mark so the receiver can settle
        for code in baudot(text) {
            emit(space, bitLen)
            for i in 0..<5 { emit((code >> i) & 1 == 1 ? mark : space, bitLen) }
            emit(mark, bitLen * 1.5)
        }
        emit(mark, bitLen * 3)
        fade(&out)
        return out
    }

    // MARK: FT8 and FT4

    /// One FT8 or FT4 transmission from ft8_lib, or nil if the text doesn't pack.
    static func ftx(text: String, ft4: Bool) -> [Float]? {
        let need = Int(cft8_length(ft4 ? 1 : 0, Int32(sampleRate)))
        var out = [Float](repeating: 0, count: need)
        let n = cft8_render(text, ft4 ? 1 : 0, 1500, Int32(sampleRate), &out, Int32(need))
        guard n > 0 else { return nil }
        return out.map { $0 * 0.7 }
    }

    /// 16-bit mono WAV, used to check generated signals with independent decoders.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2), rate = UInt32(sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}

/// Turns a mode, message and callsign into audio, and says why one can't be sent.
enum TxSignal {
    private static func base(_ callsign: String) -> String { String(callsign.split(separator: "-").first ?? "") }

    /// Stations must identify, so plain-text modes add the callsign when the message lacks it.
    static func identified(_ text: String, callsign: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.uppercased().contains(base(callsign)) ? t : "\(t) DE \(base(callsign))"
    }

    static func problem(mode: TxMode, message: String, callsign: String) -> String? {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .fmVoice, .ssbVoice: return nil
        case .ft8, .ft4:
            if t.isEmpty { return "Type a message" }
            if !t.uppercased().contains(base(callsign)) { return "Message must include your callsign" }
            return cft8_valid(t.uppercased()) == 1 ? nil : "Not a valid \(mode.rawValue) message"
        case .aprsPosition:
            // The message is the finished position report, which needs a location of your own.
            return t.isEmpty ? "Set your own location in the address bar" : nil
        case .aprs, .packet1200, .packet9600, .cw, .psk31, .rtty:
            return t.isEmpty ? "Type a message" : nil
        }
    }

    static func render(mode: TxMode, message: String, callsign: String, path: [String], usb: Bool) -> [Float]? {
        guard problem(mode: mode, message: message, callsign: callsign) == nil else { return nil }
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = identified(t, callsign: callsign)
        switch mode {
        case .fmVoice, .ssbVoice: return nil
        case .cw: return AudioSignals.cw(text: text)
        case .aprs: return AudioSignals.aprs(source: callsign, path: path, text: t)
        case .aprsPosition: return AudioSignals.aprsPacket(source: callsign, path: path, info: t)
        case .packet1200: return AudioSignals.packet1200(source: callsign, path: path, text: t)
        case .packet9600: return AudioSignals.packet9600(source: callsign, path: path, text: t)
        case .psk31: return AudioSignals.psk31(text: text)
        case .rtty: return AudioSignals.rtty(text: text, usb: usb)
        case .ft8: return AudioSignals.ftx(text: t.uppercased(), ft4: false)
        case .ft4: return AudioSignals.ftx(text: t.uppercased(), ft4: true)
        }
    }
}
