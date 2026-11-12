import Foundation
import CSSDV

/// Pictures sent as numbered data packets (SSDV). Finds the packets in whatever bytes have been
/// decoded, and rebuilds each picture as its packets arrive. A lost packet leaves a grey patch.
final class SSDVAssembler {
    struct Key: Hashable {
        let callsign: String
        let imageID: Int
    }

    struct Picture {
        var width = 0
        var height = 0
        var packets: [Int: [UInt8]] = [:]
        var lastPacket: Int?

        /// How many packets the whole picture has, once its final one has been seen.
        var total: Int? { lastPacket.map { $0 + 1 } }
        var isComplete: Bool { total.map { packets.count >= $0 } ?? false }
    }

    private(set) var pictures: [Key: Picture] = [:]
    static let packetSize = Int(CSSDV_PACKET)

    /// Valid packets anywhere in a run of bytes. Some links drop the leading sync byte, so a
    /// packet is also looked for one byte short, and given its sync byte back.
    static func packets(in bytes: [UInt8]) -> [(info: cssdv_info, packet: [UInt8])] {
        var out: [(cssdv_info, [UInt8])] = []
        var i = 0
        while i < bytes.count {
            var found = false
            if bytes[i] == 0x55, i + packetSize <= bytes.count, i + 1 < bytes.count, bytes[i + 1] == 0x66 || bytes[i + 1] == 0x67 {
                var p = Array(bytes[i..<(i + packetSize)])
                var info = cssdv_info()
                if cssdv_check(&p, &info) == 1 { out.append((info, p)); i += packetSize; found = true }
            }
            if !found, bytes[i] == 0x66 || bytes[i] == 0x67, i + packetSize - 1 <= bytes.count {
                var p = [0x55] + Array(bytes[i..<(i + packetSize - 1)])
                var info = cssdv_info()
                if cssdv_check(&p, &info) == 1 { out.append((info, p)); i += packetSize - 1; found = true }
            }
            if !found { i += 1 }
        }
        return out
    }

    private static func name(_ info: cssdv_info) -> String {
        withUnsafeBytes(of: info.callsign) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Takes in more decoded bytes. Returns the pictures that gained a packet.
    @discardableResult func feed(_ bytes: [UInt8]) -> Set<Key> {
        var changed = Set<Key>()
        for (info, packet) in Self.packets(in: bytes) {
            let key = Key(callsign: Self.name(info), imageID: Int(info.image_id))
            var pic = pictures[key] ?? Picture()
            guard pic.packets[Int(info.packet_id)] == nil else { continue }
            pic.packets[Int(info.packet_id)] = packet
            pic.width = Int(info.width)
            pic.height = Int(info.height)
            if info.last != 0 { pic.lastPacket = Int(info.packet_id) }
            pictures[key] = pic
            changed.insert(key)
        }
        return changed
    }

    /// The picture so far, as a JPEG.
    func jpeg(_ key: Key) -> Data? {
        guard let pic = pictures[key], !pic.packets.isEmpty else { return nil }
        let ordered = pic.packets.keys.sorted()
        var flat: [UInt8] = []
        flat.reserveCapacity(ordered.count * Self.packetSize)
        for id in ordered { flat += pic.packets[id]! }
        var out = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
        let n = cssdv_build(flat, Int32(ordered.count), &out, Int32(out.count))
        return n > 0 ? Data(out.prefix(Int(n))) : nil
    }

    /// For tests: cuts a JPEG into packets.
    static func encode(jpeg: Data, callsign: String, imageID: Int, quality: Int = 4) -> [[UInt8]] {
        let capacity = 2048
        var out = [UInt8](repeating: 0, count: capacity * packetSize)
        let n = jpeg.withUnsafeBytes { raw in
            cssdv_encode(raw.bindMemory(to: UInt8.self).baseAddress, Int32(jpeg.count), callsign, Int32(imageID), Int32(quality), &out, Int32(capacity))
        }
        return (0..<Int(n)).map { Array(out[($0 * packetSize)..<(($0 + 1) * packetSize)]) }
    }

    static func fileName(_ key: Key) -> String {
        let safe = key.callsign.filter { $0.isLetter || $0.isNumber }
        return "ssdv_\(safe.isEmpty ? "unknown" : safe)_\(key.imageID).jpg"
    }
}
