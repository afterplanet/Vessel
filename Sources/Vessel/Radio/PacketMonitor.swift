import Foundation
import SwiftUI

struct ReceivedPacket: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let frame: AX25Frame
    let report: APRSReport?

    /// One line for the log saved with the capture.
    var logLine: String {
        let clock = ISO8601DateFormatter().string(from: time)
        let path = ([frame.destination] + frame.path).joined(separator: ",")
        return "\(clock) \(frame.source)>\(path):\(frame.isBinary && report == nil ? "HEX " + frame.hexText : frame.infoText)\n"
    }
}

/// Follows the audio being captured and decodes any packets in it, whether or not the speaker is on.
@MainActor
final class PacketMonitor: ObservableObject {
    @Published private(set) var packets: [ReceivedPacket] = []
    @Published private(set) var isFollowing = false
    /// So the list doesn't grow without end on a long capture. The log keeps everything.
    static let shownAtMost = 200

    private let worker = Worker()
    private var folder: URL?

    func follow(_ next: URL?) {
        guard next != folder else { return }
        folder = next
        isFollowing = next != nil
        if next != nil { packets = [] }
        worker.follow(next) { [weak self] found in
            Task { @MainActor in self?.add(found) }
        }
    }

    private func add(_ found: [ReceivedPacket]) {
        packets.insert(contentsOf: found.reversed(), at: 0)
        if packets.count > Self.shownAtMost { packets.removeLast(packets.count - Self.shownAtMost) }
    }

    /// Only touched from its own queue.
    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "Vessel.packets")
        private var timer: DispatchSourceTimer?
        private var tail: WavTail?
        private var decoder: PacketDecoder?
        private var log: URL?
        private var send: (([ReceivedPacket]) -> Void)?
        private var ssdv = SSDVAssembler()
        private var folder: URL?

        func follow(_ folder: URL?, send: @escaping ([ReceivedPacket]) -> Void) {
            queue.async { [self] in
                if tail != nil { tick() } // What's left may hold the last packet.
                timer?.cancel(); timer = nil
                tail = nil; decoder = nil
                self.send = send
                guard let folder else { return }
                tail = WavTail(folder: folder)
                ssdv = SSDVAssembler()
                self.folder = folder
                log = folder.appendingPathComponent("packets.txt")
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: 0.25)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }

        private func tick() {
            guard let tail, let samples = tail.read(), let format = tail.format else { return }
            if decoder == nil { decoder = PacketDecoder(sampleRate: format.sampleRate) }
            guard let frames = decoder?.feed(samples), !frames.isEmpty else { return }
            // Any picture packets among them are rebuilt into a JPEG beside the capture's other files.
            for frame in frames {
                for key in ssdv.feed(frame.info) {
                    if let folder, let jpeg = ssdv.jpeg(key) {
                        try? jpeg.write(to: folder.appendingPathComponent(SSDVAssembler.fileName(key)), options: .atomic)
                    }
                }
            }
            let found = frames.map { ReceivedPacket(time: Date(), frame: $0, report: APRSReport.parse($0)) }
            save(found)
            send?(found)
        }

        private func save(_ found: [ReceivedPacket]) {
            guard let log else { return }
            let data = Data(found.map(\.logLine).joined().utf8)
            if let handle = try? FileHandle(forWritingTo: log) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: log)
            }
        }
    }
}

/// Decoded packets, in the Receiver's Capture panel.
struct PacketPanel: View {
    @ObservedObject var monitor: PacketMonitor
    let expecting: Bool
    let station: Station?
    /// What's being listened to, for reading its telemetry.
    var norad: Int?
    /// Your callsign, so messages meant for you stand out.
    let callsign: String
    let showOnGlobe: (Double, Double) -> Void

    private var base: String { callsign.split(separator: "-").first.map(String.init) ?? "" }

    var body: some View {
        if !monitor.packets.isEmpty || (expecting && monitor.isFollowing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Decoded packets").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if !monitor.packets.isEmpty {
                        Text("\(monitor.packets.count)").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if monitor.packets.isEmpty {
                    Label("Listening for packets", systemImage: "text.bubble")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(monitor.packets) { row($0) }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    private func isForYou(_ p: ReceivedPacket) -> Bool {
        guard !base.isEmpty, let to = p.report?.addressee, p.report?.kind == .message else { return false }
        return to.split(separator: "-").first.map(String.init) == base
    }

    private func row(_ p: ReceivedPacket) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(p.frame.source).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(p.report?.kind.rawValue ?? (p.frame.isBinary ? "Telemetry" : "Packet"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if isForYou(p) {
                    Text("To you").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 2)
                Text(p.time, style: .time).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let to = p.report?.addressee {
                Text("To \(to)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if p.report == nil, p.frame.isBinary {
                Text(p.frame.hexText).font(.system(size: 9, design: .monospaced)).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                PacketValues(frame: p.frame.bytes, norad: norad)
            } else {
                let text = p.report?.text ?? p.frame.infoText
                if !text.isEmpty {
                    Text(text).font(.system(size: 10)).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let lat = p.report?.latitude, let lon = p.report?.longitude {
                HStack(spacing: 5) {
                    Text(place(lat, lon)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 2)
                    Button("Show") { showOnGlobe(lat, lon) }.controlSize(.mini).help("Move the globe to this position")
                }
            }
            if !p.frame.path.isEmpty {
                Text("Via \(p.frame.path.joined(separator: ", "))").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(p.logLine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func place(_ lat: Double, _ lon: Double) -> String {
        let spot = String(format: "%.3f°, %.3f°", lat, lon)
        guard let station else { return spot }
        let km = Astro.distanceKm(lat1: station.lat, lon1: station.lon, lat2: lat, lon2: lon)
        return "\(spot), \(Int(km).formatted()) km away"
    }
}
