import Darwin
import Foundation

/// A radio found on a USB serial port.
struct FoundRadio: Equatable {
    let name: String
    let port: String
    let baud: Int
}

/// Finds radios by asking what they are. Each query is read-only: it can't tune or key anything.
enum RadioFinder {
    /// Icom CI-V reports a model byte.
    static let icomModels: [UInt8: String] = [
        0x4C: "IC-821H", 0x42: "IC-820H", 0x60: "IC-910", 0x88: "IC-7100", 0x94: "IC-7300", 0x98: "IC-7610", 0xA2: "IC-9700", 0xA4: "IC-705",
    ]
    /// Yaesu and Kenwood answer "ID;" with these.
    static let idModels: [String: String] = [
        "0570": "FT-991", "0670": "FT-991", "0761": "FTDX-10", "0681": "FTDX-101D", "0800": "FT-710", "019": "TS-2000", "021": "TS-590S", "024": "TS-890S",
    ]

    /// USB serial adapters and radios. Bluetooth and console ports are never touched.
    static func candidatePorts(in names: [String]) -> [String] {
        names.filter { name in
            ["cu.usbserial", "cu.usbmodem", "cu.SLAB_USBtoUART", "cu.wchusbserial"].contains { name.hasPrefix($0) }
        }
        .sorted()
        .map { "/dev/" + $0 }
    }

    static func ports() -> [String] {
        candidatePorts(in: (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
    }

    /// "FE FE E0 <from> 19 00 <model> FD", possibly after an echo of what was sent.
    static func parseIcom(_ reply: [UInt8]) -> String? {
        var i = 0
        while i + 7 < reply.count + 1 {
            if i + 7 <= reply.count, reply[i] == 0xFE, reply[i + 1] == 0xFE, reply[i + 2] == 0xE0, reply[i + 4] == 0x19, reply[i + 5] == 0x00,
               i + 7 < reply.count, reply[i + 7] == 0xFD {
                return icomModels[reply[i + 6]] ?? "Icom"
            }
            i += 1
        }
        return nil
    }

    static func parseID(_ reply: [UInt8]) -> String? {
        let text = String(decoding: reply, as: UTF8.self)
        guard let r = text.range(of: #"ID[0-9]{3,4};"#, options: .regularExpression) else { return nil }
        return idModels[String(text[r].dropFirst(2).dropLast())]
    }

    private static func ask(_ port: String, baud: Int, query: [UInt8], timeout: TimeInterval = 0.4) -> [UInt8] {
        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return [] }
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // Hold RTS and DTR low: on many radios one of them keys the transmitter.
        t.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { return [] }
        var lines: Int32 = 0
        ioctl(fd, TIOCMGET, &lines)
        lines &= ~(TIOCM_RTS | TIOCM_DTR)
        ioctl(fd, TIOCMSET, &lines)
        tcflush(fd, TCIOFLUSH)
        guard write(fd, query, query.count) == query.count else { return [] }
        var out: [UInt8] = []
        let end = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64)
        while Date() < end, out.count < 256 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { out += buffer[0..<n] }
        }
        return out
    }

    /// Tries the common speeds for each family. Slow, so it runs off the main thread.
    static func probe(_ port: String) -> FoundRadio? {
        let icom: [UInt8] = [0xFE, 0xFE, 0x00, 0xE0, 0x19, 0x00, 0xFD]
        for baud in [19200, 115200, 9600] {
            if let name = parseIcom(ask(port, baud: baud, query: icom)) { return FoundRadio(name: name, port: port, baud: baud) }
        }
        for baud in [38400, 9600, 4800, 115200] {
            if let name = parseID(ask(port, baud: baud, query: Array("ID;".utf8))) { return FoundRadio(name: name, port: port, baud: baud) }
        }
        return nil
    }

    /// Hamlib's number for a model, from its own list. `rigctl -l` lines start "  3081  Icom  IC-9700 …".
    static func hamlibModel(named name: String, in list: String) -> Int? {
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let number = Int(parts[0]) else { continue }
            if parts[2] == name { return number }
        }
        return nil
    }

    static func hamlibList(rigctl: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rigctl)
        p.arguments = ["-l"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
