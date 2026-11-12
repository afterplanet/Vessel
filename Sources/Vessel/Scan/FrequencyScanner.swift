import SwiftUI
import Darwin

/// Somewhere to get spectra from while stepping across the bands.
protocol ScanFeed: AnyObject {
    var maxBandwidth: Double { get }
    var minHz: Double { get }
    var maxHz: Double { get }
    var canControl: Bool { get }
    /// Widest stretch worth looking at in one go.
    var widest: Double { get }
    func open(probeHz: Double) throws
    func start(centerHz: Double, stage: Int) throws
    func tune(_ hz: Double) -> Bool
    func nextFrame(timeout: TimeInterval) throws -> [Float]
    func close()
}

/// Watches a SpyServer's own waterfall stream. The server computes the spectrum and sends only
/// the picture, about 100 KB/s, so this works even on hosts far too slow to send raw samples.
final class SpyFFTLink: ScanFeed {
    struct Failure: Error { let message: String }

    let widest = 2_000_000.0
    private var host = ""
    private var port = 0

    convenience init(pixels: Int, host: String, port: Int) {
        self.init(pixels: pixels)
        self.host = host
        self.port = port
    }

    func open(probeHz: Double) throws { try connect(host: host, port: port) }

    private var fd: Int32 = -1
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)
    private(set) var maxBandwidth = 0.0
    private(set) var minHz = 0.0
    private(set) var maxHz = 0.0
    private(set) var canControl = true
    private(set) var fftCenter = 0.0
    private let pixels: Int
    /// Decibels spanned by the stream's 8-bit values.
    static let rangeDB: UInt32 = 120

    init(pixels: Int) { self.pixels = pixels }
    deinit { close() }

    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    private func send(_ words: [UInt32], tail: [UInt8] = []) -> Bool {
        let bytes = words.flatMap { w in withUnsafeBytes(of: w.littleEndian) { Array($0) } } + tail
        return write(fd, bytes, bytes.count) == bytes.count
    }

    private func setting(_ s: UInt32, _ v: UInt32) -> Bool { send([2, 8, s, v]) }

    private func read(_ count: Int, timeout: TimeInterval) -> Bool {
        if buffer.count < count { buffer = [UInt8](repeating: 0, count: count) }
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < count {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0, poll(&p, 1, left) > 0 else { return false }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            guard n > 0 else { return false }
            got += n
        }
        return true
    }

    private func word(_ at: Int) -> UInt32 {
        UInt32(buffer[at]) | UInt32(buffer[at + 1]) << 8 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 24
    }

    func connect(host: String, port: Int) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw Failure(message: "Couldn't find this host") }
        defer { freeaddrinfo(ai) }
        fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { throw Failure(message: "This host isn't answering") }

        let name = Array("Vessel".utf8)
        guard send([0, UInt32(4 + name.count), (2 << 24) | 1700], tail: name) else { throw Failure(message: "Lost the connection") }
        guard read(20, timeout: 5) else { throw Failure(message: "This host didn't answer. It may be full.") }
        let body = Int(word(16))
        guard word(4) == 0, body >= 36, body < 4096, read(body, timeout: 5) else { throw Failure(message: "This host sent something unexpected") }
        maxBandwidth = Double(word(12))
        minHz = Double(word(28))
        maxHz = Double(word(32))
    }

    /// The server only streams its waterfall alongside IQ, so IQ is kept at the lowest rate it has.
    func start(centerHz: Double, stage: Int) throws {
        let steps: [(UInt32, UInt32)] = [(0, 5), (100, 1), (102, 8), (101, UInt32(centerHz)), (200, 1), (205, UInt32(pixels)),
                                         (204, Self.rangeDB), (203, 0), (202, UInt32(stage)), (201, UInt32(centerHz)), (1, 1)]
        for (s, v) in steps where !setting(s, v) { throw Failure(message: "Lost the connection") }
    }

    func tune(_ hz: Double) -> Bool { setting(101, UInt32(hz)) && setting(201, UInt32(hz)) }

    /// Next spectrum in dB, skipping everything else in the stream.
    func nextFrame(timeout: TimeInterval = 4) throws -> [Float] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard read(20, timeout: timeout) else { throw Failure(message: "The stream stopped") }
            let type = word(4) & 0xFFFF, size = Int(word(16))
            guard size >= 0, size < 1 << 22, read(size, timeout: timeout) else { throw Failure(message: "The stream stopped") }
            if type == 1, size >= 20 {
                canControl = word(0) != 0
                fftCenter = Double(word(16))
            }
            if type == 301 {
                let scale = Float(Self.rangeDB) / 255
                return buffer[0..<size].map { Float($0) * scale }
            }
        }
        throw Failure(message: "No waterfall from this host")
    }
}

@MainActor
final class FrequencyScanner: ObservableObject {
    enum State: Equatable { case idle, connecting, scanning, stopped, failed(String) }

    @Published private(set) var state = State.idle
    @Published private(set) var candidates: [ScanCandidate] = []
    @Published private(set) var windows: [ScanWindow] = []
    @Published private(set) var current: ScanWindow?
    /// The one on screen. Nil follows the sweep.
    @Published var viewing: ScanWindow?
    @Published private(set) var picture: CGImage?
    @Published private(set) var sweeps = 0
    @Published private(set) var elevation: Double?

    private var worker: Task<Void, Never>?
    private var pictures: [Double: Waterfall] = [:]
    private var tracker: ScanTracker?

    /// A scrolling picture for one window, oldest row at the bottom.
    final class Waterfall {
        static let width = 1024, rows = 180
        var pixels = [UInt8](repeating: 0, count: Waterfall.width * Waterfall.rows * 4)

        func add(_ v: [Float]) {
            guard v.count >= Self.width else { return }
            let row = Self.width * 4
            pixels.withUnsafeMutableBufferPointer { p in
                memmove(p.baseAddress! + row, p.baseAddress!, row * (Self.rows - 1))
            }
            let mid = v.sorted()[v.count / 2]
            let per = v.count / Self.width
            for x in 0..<Self.width {
                // The strongest of each group, so a narrow signal survives being scaled down.
                var top = v[x * per]
                for k in 1..<max(per, 1) where v[x * per + k] > top { top = v[x * per + k] }
                let level = max(0, min(1, (top - mid + 8) / 36))
                let (r, g, b) = SpectrumFeed.color(level)
                pixels[x * 4] = r; pixels[x * 4 + 1] = g; pixels[x * 4 + 2] = b; pixels[x * 4 + 3] = 255
            }
        }

        var image: CGImage? {
            pixels.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: Self.width, height: Self.rows, bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }
    }

    var isRunning: Bool { state == .connecting || state == .scanning }

    func start(source: ScanSource, bands: [ScanBand], satellite: Satellite, station: Station) {
        stop()
        candidates = []
        windows = []
        pictures = [:]
        picture = nil
        viewing = nil
        sweeps = 0
        state = .connecting
        guard let clone = satellite.clone() else { state = .failed("Couldn't read this satellite's orbit"); return }
        let box = UncheckedBox(clone)
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(source: source, bands: bands, sat: box, station: station)
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        if isRunning { state = .stopped }
    }

    func show(_ w: ScanWindow?) {
        viewing = w
        refreshPicture()
    }

    private func refreshPicture() {
        if let w = viewing ?? current { picture = pictures[w.centerHz]?.image }
    }

    nonisolated private func run(source: ScanSource, bands: [ScanBand], sat: UncheckedBox<Satellite>, station: Station) async {
        let link = source.makeFeed()
        defer { link.close() }
        do {
            var opened: (windows: [ScanWindow], stage: Int)?
            // The app's own host check can be holding the only slot for a moment, and on a
            // busy host control may take a moment to arrive, so the start gets a few tries.
            for attempt in 1...3 where opened == nil {
                do {
                    link.close()
                    try link.open(probeHz: bands.first.map { ($0.lowHz + $0.highHz) / 2 } ?? 137_500_000)
                    let plan = ScanWindow.plan(bands: bands, maxBandwidth: link.maxBandwidth, minHz: link.minHz, maxHz: link.maxHz, widest: link.widest)
                    guard let first = plan.windows.first else {
                        throw SpyFFTLink.Failure(message: "This host can't reach any of the chosen bands")
                    }
                    try link.start(centerHz: first.centerHz, stage: plan.stage)
                    let settle = Date().addingTimeInterval(0.8)
                    while Date() < settle { _ = try link.nextFrame(timeout: 4) }
                    guard link.canControl else {
                        throw SpyFFTLink.Failure(message: "Someone else is using this host, or its owner doesn't allow retuning.")
                    }
                    opened = plan
                } catch {
                    if attempt == 3 || Task.isCancelled { throw error }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            guard let plan = opened, let first = plan.windows.first else { return }
            var tracker = ScanTracker(resolutionHz: first.spanHz / 4096)
            await begin(plan.windows)

            var sweep = 0
            while !Task.isCancelled {
                for window in plan.windows {
                    if Task.isCancelled { return }
                    guard link.tune(window.centerHz) else { throw SpyFFTLink.Failure(message: "Lost the connection") }
                    await setCurrent(window)
                    // Frames already on their way are from the last tune.
                    let settle = Date().addingTimeInterval(0.4)
                    while Date() < settle { _ = try link.nextFrame(timeout: 4) }
                    if !link.canControl {
                        throw SpyFFTLink.Failure(message: "This host stopped allowing retuning. Someone else may be using it.")
                    }
                    var sum = [Float](repeating: 0, count: 0)
                    var frames = 0
                    let end = Date().addingTimeInterval(1.6)
                    while Date() < end, !Task.isCancelled {
                        let v = try link.nextFrame(timeout: 4)
                        if sum.count != v.count { sum = [Float](repeating: 0, count: v.count); frames = 0 }
                        for i in 0..<v.count { sum[i] += v[i] }
                        frames += 1
                        await addRow(v, window: window)
                    }
                    guard frames > 0 else { continue }
                    let avg = sum.map { $0 / Float(frames) }
                    let jd = Astro.julianDate()
                    guard let a = Self.look(sat.value, station, jd), let b = Self.look(sat.value, station, jd + 1.0 / 86400) else { continue }
                    // Anything seen with the satellite below the horizon can't be it.
                    if a.el > 0 {
                        for d in ScanPeaks.find(spectrum: avg, centerHz: window.centerHz, spanHz: window.spanHz) {
                            tracker.add(d, rangeRate: b.range - a.range, time: Date().timeIntervalSinceReferenceDate)
                        }
                    }
                    await update(tracker.candidates, elevation: a.el)
                }
                sweep += 1
                await setSweeps(sweep)
            }
        } catch let f as SpyFFTLink.Failure {
            await fail(f.message)
        } catch {
            await fail(error.localizedDescription)
        }
    }

    nonisolated private static func look(_ sat: Satellite, _ st: Station, _ jd: Double) -> (az: Double, el: Double, range: Double)? {
        guard let s = sat.state(jd: jd) else { return nil }
        return Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon)
    }

    private func begin(_ w: [ScanWindow]) {
        windows = w
        state = .scanning
    }

    private func setCurrent(_ w: ScanWindow) {
        current = w
        if viewing == nil { refreshPicture() }
    }

    private var rowCounter = 0

    private func addRow(_ v: [Float], window: ScanWindow) {
        let fall = pictures[window.centerHz] ?? Waterfall()
        pictures[window.centerHz] = fall
        fall.add(v)
        rowCounter += 1
        // Quarter-speed is plenty for the eye, and keeps this light.
        if rowCounter % 3 == 0, (viewing ?? current) == window { picture = fall.image }
    }

    private func update(_ c: [ScanCandidate], elevation e: Double) {
        if c != candidates { candidates = c }
        elevation = e
    }

    private func setSweeps(_ n: Int) { sweeps = n }
    private func fail(_ m: String) { state = .failed(m) }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Elevation of a satellite from everywhere it might be heard, for choosing a host that can see it now.
enum ScanHosts {
    static func best(_ hosts: [SpyHost], satellite: Satellite, bands: [ScanBand], minElevation: Double = 10) -> (host: SpyHost, elevation: Double)? {
        guard let clone = satellite.clone() else { return nil }
        let jd = Astro.julianDate()
        guard let s = clone.state(jd: jd) else { return nil }
        let target = Astro.ecef(s.r, gmst: Astro.gmst(jd))
        var best: (SpyHost, Double)?
        for h in hosts where h.fullControl && bands.contains(where: { $0.reachable(minHz: h.minHz, maxHz: h.maxHz) }) {
            let el = Astro.lookAngles(target: target, latDeg: h.lat, lonDeg: h.lon).el
            if el >= minElevation, el > (best?.1 ?? -90) { best = (h, el) }
        }
        return best.map { (host: $0.0, elevation: $0.1) }
    }
}
