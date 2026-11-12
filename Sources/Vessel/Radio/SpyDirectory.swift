import Foundation
import Darwin

/// A public SpyServer from the Airspy directory. Almost every field can be null there.
struct SpyHost: Identifiable, Hashable {
    enum Network: String { case spyServer, webSDR }

    var id: String { "\(host):\(port)" }
    var network: Network = .spyServer
    var city: String = ""
    var state: String = ""
    /// The directory itself says this host is offline.
    var listedOffline = false
    var antenna = ""
    var resolutionBits = 0
    let host: String
    let port: Int
    let device: String
    let details: String
    let lat: Double
    let lon: Double
    let minHz: Double
    let maxHz: Double
    let maxSampleRate: Double
    let maxBandwidth: Double
    let clients: Int
    let maxClients: Int
    let fullControl: Bool
    let iso: String

    func covers(_ hz: Double) -> Bool { hz >= minHz && hz <= maxHz }
    var isFull: Bool { maxClients > 0 && clients >= maxClients }
    /// For test logs.
    @MainActor func status(_ app: AppState) -> Int { app.status(of: self).rawValue }

    var countryName: String {
        OwnerCodes.countryName(iso: iso) ?? "Unknown"
    }
    var placeName: String { (localParts + [countryName]).joined(separator: ", ") }
    /// For lists: the country, then its state, or the city where no state is known.
    var shortName: String { Self.shortName(country: countryName, state: state, city: city) }

    static func shortName(country: String, state: String, city: String) -> String {
        let area = state.isEmpty ? city : state
        return area.isEmpty || area == country ? country : "\(country), \(area)"
    }
    private var localParts: [String] {
        var parts: [String] = []
        if !city.isEmpty { parts.append(city) }
        if !state.isEmpty, state != city { parts.append(state) }
        return parts
    }
    /// Web SDRs are listened to in a browser. SatDump has no source for them.
    var webURL: URL? { network == .webSDR ? URL(string: "http://\(host):\(port)") : nil }

    /// SpyServer only offers its maximum rate divided by powers of two, so snap to the
    /// smallest one that still fits the pipeline's request.
    func snappedRate(for wanted: Double) -> Double {
        var r = maxSampleRate
        while r / 2 >= wanted, r > 1 { r /= 2 }
        return r
    }
}

/// What a host's live check found. `nil` in the table means it hasn't been checked yet.
enum HostHealth { case answering, silent }

/// The coloured bar beside a host, in the order the list shows them.
enum HostRanking {
    /// The closest host that's working, for a place someone searched for.
    static func nearestWorking(_ hosts: [SpyHost], to place: Station, status: (SpyHost) -> HostStatus) -> SpyHost? {
        hosts.filter { status($0) == .available }.min {
            Astro.distanceKm(lat1: place.lat, lon1: place.lon, lat2: $0.lat, lon2: $0.lon)
                < Astro.distanceKm(lat1: place.lat, lon1: place.lon, lat2: $1.lat, lon2: $1.lon)
        }
    }


    struct Region {
        let hosts: [SpyHost]
        /// Nil when nothing alive was in reach, and these are just the closest hosts anywhere.
        let radiusKm: Double?
    }

    /// Hosts around a clicked spot, closest first. Hosts are thin on the ground
    /// in most of the world, so the area widens until it holds a few that are alive.
    static func around(_ hosts: [SpyHost], place: Station, status: (SpyHost) -> HostStatus) -> Region {
        // A host with no country has no real position: many just publish 0°, 0°.
        let rows = closestFirst(hosts.filter { !$0.iso.isEmpty }, to: place, status: status)
        let steps: [Double] = [300, 600, 1200, 2500, 5000]
        let enough = 5
        let widest = steps[steps.count - 1]
        guard rows.contains(where: { $0.km <= widest && $0.status != .dead }) else {
            let alive = rows.filter { $0.status != .dead }
            let closest = Set((alive.isEmpty ? rows : alive).sorted { $0.km < $1.km }.prefix(enough).map(\.host.id))
            return Region(hosts: rows.filter { closest.contains($0.host.id) }.map(\.host), radiusKm: nil)
        }
        let radius = steps.first { r in rows.filter { $0.km <= r && $0.status != .dead }.count >= enough } ?? widest
        return Region(hosts: rows.filter { $0.km <= radius }.map(\.host), radiusKm: radius)
    }

    /// Around a place, distance decides, using each host's own coordinates: a host over a border can
    /// be the closest one. Dead hosts go last, since they're no use however near.
    static func sort(_ hosts: [SpyHost], near place: Station?, status: (SpyHost) -> HostStatus) -> [SpyHost] {
        guard let place else {
            return hosts.map { (host: $0, status: status($0)) }.sorted { a, b in
                if a.status != b.status { return a.status < b.status }
                if a.host.placeName != b.host.placeName { return a.host.placeName < b.host.placeName }
                return a.host.id < b.host.id
            }.map(\.host)
        }
        return closestFirst(hosts, to: place, status: status).map(\.host)
    }

    private static func closestFirst(_ hosts: [SpyHost], to place: Station, status: (SpyHost) -> HostStatus)
        -> [(host: SpyHost, status: HostStatus, km: Double)] {
        hosts.map { h in
            (host: h, status: status(h), km: Astro.distanceKm(lat1: place.lat, lon1: place.lon, lat2: h.lat, lon2: h.lon))
        }.sorted { a, b in
            if (a.status == .dead) != (b.status == .dead) { return b.status == .dead }
            if a.km != b.km { return a.km < b.km }
            return a.host.id < b.host.id
        }
    }
}

enum HostStatus: Int, Comparable {
    case available, checking, unavailable, dead

    static func < (a: HostStatus, b: HostStatus) -> Bool { a.rawValue < b.rawValue }

    /// A failed check beats everything. Otherwise a working host can still be full, or be
    /// unable to reach the locked satellite's frequency.
    static func resolve(_ h: SpyHost, health: HostHealth?, frequency: Double?, tooSlow: Bool = false) -> HostStatus {
        if h.listedOffline || health == .silent { return .dead }
        guard health != nil else { return .checking }
        if h.isFull || tooSlow { return .unavailable }
        if let frequency, !h.covers(frequency) { return .unavailable }
        if h.network == .spyServer, !h.fullControl { return .unavailable }
        return .available
    }
}

/// Live checks. A TCP connect isn't enough for SpyServer: some hosts accept the connection and
/// then never answer, which stalls SatDump. So those get a real handshake where a slot is free.
/// How good the path to a host is. This measures latency and loss, not spare bandwidth.
struct HostLink: Equatable {
    let roundTripMs: Double?
    let lost: Int

    /// 0 to 5 bars.
    var bars: Int {
        guard let ms = roundTripMs else { return 0 }
        let base = ms < 60 ? 5 : ms < 120 ? 4 : ms < 200 ? 3 : ms < 350 ? 2 : 1
        return max(1, base - lost)
    }

    var word: String {
        switch bars {
        case 5: "Excellent"
        case 4: "Strong"
        case 3: "Good"
        case 2: "Fair"
        case 1: "Weak"
        default: "No response"
        }
    }
}

enum HostProbe {
    /// One per network, so a long directory of dead hosts can't hold up the other list.
    private static let queues: [SpyHost.Network: OperationQueue] = {
        var all: [SpyHost.Network: OperationQueue] = [:]
        for network in [SpyHost.Network.spyServer, .webSDR] {
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 16
            q.qualityOfService = .utility
            all[network] = q
        }
        return all
    }()

    static func check(_ h: SpyHost, timeout: TimeInterval = 4) async -> HostHealth {
        await withCheckedContinuation { c in
            queues[h.network]!.addOperation { c.resume(returning: run(h, timeout) ? .answering : .silent) }
        }
    }

    /// For a host someone just clicked: skips the queue the background health checks share.
    /// How fast a SpyServer really delivers at this rate, in bytes per second, by streaming for a
    /// few seconds at 8 bits exactly as a capture would. Nil means it couldn't be measured.
    static func throughput(_ h: SpyHost, sampleRate: Double, frequency: Double, seconds: TimeInterval = 3) async -> Double? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: measure(h, sampleRate, frequency, seconds))
            }
        }
    }

    private static func measure(_ h: SpyHost, _ sampleRate: Double, _ frequency: Double, _ seconds: TimeInterval) -> Double? {
        guard let fd = open(h.host, h.port, 3) else { return nil }
        defer { close(fd) }
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        func send(_ b: [UInt8]) -> Bool { write(fd, b, b.count) == b.count }
        func setting(_ s: UInt32, _ v: UInt32) -> Bool { send(le(2) + le(8) + le(s) + le(v)) }
        let name = Array("Vessel".utf8)
        guard send(le(0) + le(UInt32(4 + name.count)) + le((2 << 24) | 1700) + name) else { return nil }

        // Device info comes first, and holds the true top rate that decimation counts down from.
        var buf = [UInt8](repeating: 0, count: 65536)
        func readExactly(_ count: Int, deadline: Date) -> Bool {
            var got = 0
            while got < count {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let left = Int32(deadline.timeIntervalSinceNow * 1000)
                guard left > 0, poll(&p, 1, left) > 0 else { return false }
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
                guard n > 0 else { return false }
                got += n
            }
            return true
        }
        func u32(_ at: Int) -> UInt32 { UInt32(buf[at]) | UInt32(buf[at + 1]) << 8 | UInt32(buf[at + 2]) << 16 | UInt32(buf[at + 3]) << 24 }
        let setup = Date().addingTimeInterval(4)
        guard readExactly(20, deadline: setup), u32(4) == 0 else { return nil }
        let body = Int(u32(16))
        guard body >= 12, body <= 1024, readExactly(body, deadline: setup) else { return nil }
        let top = Double(u32(8))
        guard top > 0, sampleRate > 0 else { return nil }
        let stage = UInt32(max(0, (log2(top / sampleRate)).rounded()))

        // Format 1 is 8-bit, mode 1 is IQ only, and setting 1 starts the stream.
        guard setting(100, 1), setting(0, 1), setting(102, stage), setting(101, UInt32(frequency)), setting(1, 1) else { return nil }

        // The first moment is TCP ramping up and the server's backlog, neither of which is the real rate.
        let start = Date()
        let settle = start.addingTimeInterval(0.8)
        let end = settle.addingTimeInterval(seconds)
        var counted = 0
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(1, end.timeIntervalSinceNow * 1000))) > 0 else { continue }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, 65536) }
            guard n > 0 else { break }
            if Date() >= settle { counted += n }
        }
        return Double(counted) / seconds
    }

    static func checkNow(_ h: SpyHost, timeout: TimeInterval = 3) async -> HostHealth {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: run(h, timeout) ? .answering : .silent)
            }
        }
    }

    /// Round trip to a host, from how long TCP connects take. Three tries, without saying hello,
    /// so it never takes up a listener slot or disturbs a stream already running.
    /// `background` waits its turn with that network's other checks, for measuring a whole list.
    static func measureLink(host: String, port: Int, background: SpyHost.Network? = nil) async -> HostLink {
        await withCheckedContinuation { c in
            let work = {
                var times: [Double] = []
                for _ in 0..<3 {
                    let start = Date()
                    if let fd = open(host, port, 2) {
                        times.append(Date().timeIntervalSince(start) * 1000)
                        close(fd)
                    }
                }
                let sorted = times.sorted()
                c.resume(returning: HostLink(roundTripMs: sorted.isEmpty ? nil : sorted[sorted.count / 2], lost: 3 - times.count))
            }
            if let background {
                // Ahead of the checks still waiting: this host is already known to be alive.
                let operation = BlockOperation(block: work)
                operation.queuePriority = .high
                queues[background]!.addOperation(operation)
            } else { DispatchQueue.global(qos: .utility).async(execute: work) }
        }
    }

    /// Connect only, for sources that aren't in a directory.
    static func connects(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        await withCheckedContinuation { c in
            // Someone is waiting on this, so it doesn't queue behind the background health checks.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let fd = open(host, port, timeout) else { c.resume(returning: false); return }
                close(fd)
                c.resume(returning: true)
            }
        }
    }

    static func run(_ h: SpyHost, _ timeout: TimeInterval) -> Bool {
        guard let fd = open(h.host, h.port, timeout) else { return false }
        defer { close(fd) }
        // A full server has no slot to spare, and the connect has already shown it's alive.
        if h.network == .webSDR || h.isFull { return true }
        return spyHandshake(fd, timeout)
    }

    private static func spyHandshake(_ fd: Int32, _ timeout: TimeInterval) -> Bool {
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let name = Array("Vessel".utf8)
        let version: UInt32 = (2 << 24) | 1700
        let hello = le(0) + le(UInt32(4 + name.count)) + le(version) + name
        guard write(fd, hello, hello.count) == hello.count else { return false }
        // The reply starts with a 20-byte header: protocol ID, then message type (0 is device info).
        var header = [UInt8](repeating: 0, count: 20)
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < header.count {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0, poll(&p, 1, left) > 0 else { return false }
            let n = header.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, 20 - got) }
            guard n > 0 else { return false }
            got += n
        }
        return header[3] == 2 && header[4] == 0 && header[5] == 0
    }

    /// A connected socket, or nil. Dead addresses are common, so this always has a deadline.
    private static func open(_ host: String, _ port: Int, _ timeout: TimeInterval) -> Int32? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { return fd }
            if errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, Int32(timeout * 1000)) > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 { return fd }
                }
            }
            close(fd)
        }
        return nil
    }
}

enum SpyDirectory {
    private struct Raw: Decodable {
        struct Loc: Decodable { let lat: Double?; let long: Double? }
        let streamingHost: String?
        let streamingPort: Int?
        let deviceType: String?
        let generalDescription: String?
        let antennaLocation: Loc?
        let minimumFrequency: Double?
        let maximumFrequency: Double?
        let maximumIQSampleRate: Double?
        let maximumStreamedBandwidth: Double?
        let currentClientCount: Int?
        let maxClients: Int?
        let fullControlAllowed: Bool?
        let online: Bool?
        let antennaType: String?
        let deviceResolution: Int?
    }
    private struct Root: Decodable { let servers: [Raw] }

    static func fetch() async throws -> [SpyHost] {
        let data = try await DataFetcher.data("https://airspy.com/directory/status.json",
                                              cacheName: "spy_hosts.json", maxAge: 60)
        return try await Task.detached(priority: .utility) { () -> [SpyHost] in
            let root = try JSONDecoder().decode(Root.self, from: data)
            return root.servers.compactMap { s in
                guard let host = s.streamingHost, !host.isEmpty, let port = s.streamingPort,
                      let lat = s.antennaLocation?.lat, let lon = s.antennaLocation?.long,
                      let minF = s.minimumFrequency, let maxF = s.maximumFrequency,
                      let rate = s.maximumIQSampleRate else { return nil }
                var entry = SpyHost(listedOffline: s.online != true, host: host, port: port, device: s.deviceType ?? "SDR",
                               details: (s.generalDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                               lat: lat, lon: lon, minHz: minF, maxHz: maxF, maxSampleRate: rate,
                               maxBandwidth: s.maximumStreamedBandwidth ?? rate,
                               clients: s.currentClientCount ?? 0, maxClients: s.maxClients ?? 0,
                               fullControl: s.fullControlAllowed ?? false,
                               iso: Countries.shared.iso(lat: lat, lon: lon))
                if let near = Places.shared.nearest(lat: lat, lon: lon) {
                    entry.city = near.name
                    entry.state = near.state
                }
                entry.antenna = (s.antennaType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                entry.resolutionBits = s.deviceResolution ?? 0
                return entry
            }
        }.value
    }

    private struct WebRaw: Decodable {
        let name: String?
        let hostname: String?
        let port: Int?
        let bandwidth: Double?
        let users: Int?
        let max_users: Int?
        let lat_jittered: Double?
        let lon_jittered: Double?
        let software: String?
        let range_start_hz: Double?
        let range_end_hz: Double?
        let location_city: String?
    }

    /// sdr-list.xyz: public web receivers. Most cover HF only, and they can't feed SatDump.
    /// Uses the published position, which the directory deliberately blurs a little.
    static func fetchWeb() async throws -> [SpyHost] {
        let data = try await DataFetcher.data("https://sdr-list.xyz/api/v1/receivers", cacheName: "web_sdrs.json", maxAge: 60)
        return try await Task.detached(priority: .utility) { () -> [SpyHost] in
            try JSONDecoder().decode([WebRaw].self, from: data).compactMap { s in
                guard let host = s.hostname, !host.isEmpty, let port = s.port,
                      let lat = s.lat_jittered, let lon = s.lon_jittered,
                      let minF = s.range_start_hz, let maxF = s.range_end_hz else { return nil }
                let software = (s.software ?? "").isEmpty ? "Web SDR" : s.software!
                var entry = SpyHost(network: .webSDR, city: s.location_city ?? "", host: host, port: port, device: software,
                               details: s.name ?? "", lat: lat, lon: lon, minHz: minF, maxHz: maxF,
                               maxSampleRate: s.bandwidth ?? 0, maxBandwidth: s.bandwidth ?? 0,
                               clients: s.users ?? 0, maxClients: s.max_users ?? 0, fullControl: true,
                               iso: Countries.shared.iso(lat: lat, lon: lon))
                // The same names as the other network, from the same offline lookup.
                if let near = Places.shared.nearest(lat: lat, lon: lon) {
                    entry.state = near.state
                    if entry.city.isEmpty { entry.city = near.name }
                }
                return entry
            }
        }.value
    }
}
