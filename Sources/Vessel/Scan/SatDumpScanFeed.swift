import Foundation

/// What the scan listens through: always the source chosen in the Listener panel.
enum ScanSource {
    struct Engine {
        let executable: URL
        let source: SDRSource
        let address: String
        let port: Int
        let gain: Double?
        let bias: Bool
        let extraArgs: [String]
        let rates: [Double]
    }

    /// A SpyServer's own waterfall, which is fast and light on the connection.
    case spy(SpyHost)
    /// Any other radio, through the decoder engine.
    case engine(Engine)

    func makeFeed() -> ScanFeed {
        switch self {
        case .spy(let h): return SpyFFTLink(pixels: 4096, host: h.host, port: h.port)
        case .engine(let e): return SatDumpScanFeed(e)
        }
    }
}

/// Reads spectra from the decoder engine for any radio it supports. The engine can't retune while
/// running, so each window needs a restart, which takes a few seconds. Nothing is kept on disk.
final class SatDumpScanFeed: ScanFeed {
    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: Process] = [:]

    /// So a quit can't leave a radio held by an orphaned process.
    static func stopAll() {
        lock.lock(); let all = Array(running.values); lock.unlock()
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        clearOldFolders()
    }

    /// Anything left from a crash or a forced quit.
    static func clearOldFolders() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("vessel-scan-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private let config: ScanSource.Engine
    private var process: Process?
    private var folder: URL?
    private var httpPort = 0
    private var launchedAt = Date()
    private var rate = 0.0
    private var center = 0.0
    private var previous: [Float] = []

    /// Slow starts are normal: the engine loads every plugin and opens the radio.
    static let startupTimeout: TimeInterval = 25
    static let pixels = 4096

    var maxBandwidth: Double { rate }
    let minHz = 0.0
    let maxHz = 100_000_000_000.0
    let canControl = true
    var widest: Double { rate }

    init(_ config: ScanSource.Engine) {
        self.config = config
        Self.clearOldFolders()
    }
    deinit { close() }

    static func arguments(_ c: ScanSource.Engine, output: String, rate: Double, centerHz: Double, httpPort: Int) -> [String] {
        var args = ["legacy", "record", output, "--baseband_format", "cs8",
                    "--fft_enable", "--fft_size", String(pixels), "--fft_rate", "10",
                    "--source", c.source.id, "--samplerate", String(Int64(rate)), "--frequency", String(Int64(centerHz)),
                    "--http_server", "127.0.0.1:\(httpPort)"]
        if let flag = c.source.addressFlag, !c.address.isEmpty { args += ["--\(flag)", c.address] }
        if c.source.defaultPort != nil { args += ["--port", String(c.port)] }
        if let flag = c.source.gainFlag, let g = c.gain { args += ["--\(flag)", String(Int(g))] }
        if !c.source.bitDepths.isEmpty { args += ["--bit_depth", "8"] }
        if c.bias, c.source.hasBias { args += ["--bias"] }
        return args + c.extraArgs
    }

    /// Finds a rate this radio accepts, by trying them.
    func open(probeHz: Double) throws {
        var last: Error = SpyFFTLink.Failure(message: "This radio didn't start")
        for r in config.rates {
            rate = r
            do {
                try launch(centerHz: probeHz)
                _ = try nextFrame(timeout: 4)
                return
            } catch { last = error }
            stopProcess()
        }
        throw last
    }

    func start(centerHz: Double, stage: Int) throws {
        if centerHz != center || process?.isRunning != true { try launch(centerHz: centerHz) }
    }

    func tune(_ hz: Double) -> Bool {
        if hz == center, process?.isRunning == true { return true }
        do {
            try launch(centerHz: hz)
            return true
        } catch {
            return false
        }
    }

    private func launch(centerHz: Double) throws {
        stopProcess()
        center = centerHz
        previous = []
        httpPort = Int.random(in: 19000...19999)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vessel-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The engine insists on writing what it receives. A scan has no use for it.
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("scan.cs8").path, withDestinationPath: "/dev/null")
        folder = dir
        let p = Process()
        p.executableURL = config.executable
        p.arguments = Self.arguments(config, output: dir.appendingPathComponent("scan").path, rate: rate, centerHz: centerHz, httpPort: httpPort)
        p.currentDirectoryURL = dir
        let log = dir.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = handle
        p.standardError = handle
        do { try p.run() } catch { throw SpyFFTLink.Failure(message: "Couldn't start the decoder engine") }
        launchedAt = Date()
        process = p
        Self.lock.lock(); Self.running[ObjectIdentifier(self)] = p; Self.lock.unlock()
    }

    /// The last real complaint in the engine's log, in place of a bare "it stopped".
    private func engineComplaint() -> String {
        guard let dir = folder, let text = try? String(contentsOf: dir.appendingPathComponent("log.txt"), encoding: .utf8) else {
            return "The radio stopped"
        }
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let line = clean.split(whereSeparator: \.isNewline).last { $0.contains("(E)") && !$0.contains("SDRPlay") }
        return line.map { String($0.split(separator: ")").dropFirst().joined(separator: ")")).trimmingCharacters(in: .whitespaces) } ?? "The radio stopped"
    }

    private func fetch() -> [Float]? {
        guard let url = URL(string: "http://127.0.0.1:\(httpPort)/api") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        var out: [Float]?
        URLSession.shared.dataTask(with: req) { d, _, _ in
            defer { done.signal() }
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let v = j["fft_values"] as? [Any], !v.isEmpty else { return }
            out = v.map { ($0 as? NSNumber)?.floatValue ?? -200 }
        }.resume()
        done.wait()
        return out
    }

    func nextFrame(timeout: TimeInterval) throws -> [Float] {
        // A frame that hasn't changed is the same one again, and mustn't be counted twice.
        let deadline = max(Date().addingTimeInterval(timeout), launchedAt.addingTimeInterval(Self.startupTimeout))
        while Date() < deadline {
            if process?.isRunning != true { throw SpyFFTLink.Failure(message: engineComplaint()) }
            if let v = fetch(), v != previous, v.contains(where: { $0 > -190 }) {
                previous = v
                return v
            }
            usleep(60_000)
        }
        throw SpyFFTLink.Failure(message: "No signal data from this radio. It may be busy, or out of range for this band.")
    }

    private func stopProcess() {
        if let p = process, p.isRunning {
            p.interrupt()
            let until = Date().addingTimeInterval(2)
            while p.isRunning, Date() < until { usleep(30_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
        Self.lock.lock(); Self.running[ObjectIdentifier(self)] = nil; Self.lock.unlock()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    func close() { stopProcess() }
}
