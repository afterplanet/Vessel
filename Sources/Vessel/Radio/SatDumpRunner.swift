import Foundation
import AppKit
import Darwin

enum CaptureMode: String { case listen = "Listening", record = "Recording" }

struct CaptureRequest {
    var mode: CaptureMode
    var source: SDRSource
    var address: String?
    var port: Int?
    var pipelineID: String?
    var frequencyHz: Double
    var sampleRate: Double
    var gain: Double?
    var bias: Bool
    var bitDepth: Int?
    var basebandFormat: String
    var dcBlock: Bool
    var iqSwap: Bool
    var finishProcessing: Bool
    var outputDir: URL
    var label: String
    var extraArgs: [String] = []
    var norad = 0
    var pipelineName: String? = nil
    var formatName: String? = nil
    var hostLabel: String? = nil
    /// Settings for the source itself, which apply whether decoding or only saving.
    var sourceArgs: [String] = []
    /// What to ask the receiver for, when that differs from the true frequency because its clock is off.
    var dialHz: Double? = nil
}

/// Drives the SatDump command line as a child process and reads its `/api` stats.
/// One line of the engine's device list.
struct DetectedDevice: Equatable, Sendable {
    let name: String
    let type: String

    /// Reads "(I) - Realtek RTL2838UHIDIR #00000001" followed by "(D)     - type : rtlsdr".
    static func parse(_ output: String) -> [DetectedDevice] {
        var found: [DetectedDevice] = []
        var inSources = false
        var name: String?
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("Found devices (sources)") { inSources = true; continue }
            if line.contains("Found devices (sinks)") { break }
            guard inSources else { continue }
            if let r = line.range(of: "(I) - ") {
                name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = line.range(of: "- type : "), let current = name {
                found.append(DetectedDevice(name: current, type: String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)))
                name = nil
            }
        }
        return found
    }
}

@MainActor
final class SatDumpRunner: ObservableObject {
    let health = HealthMonitor()
    @Published private(set) var executable: URL?
    @Published private(set) var isRunning = false
    /// True once SatDump's stats answer, which it only does when the source is really streaming.
    @Published private(set) var isStreaming = false
    /// Stopped capturing, and SatDump is turning what it got into images and products.
    @Published private(set) var isProcessing = false
    @Published private(set) var pipelineStatus = ""
    private(set) var lastPipelineOutcome: PipelineUpdater.Outcome?
    /// Sources whose AGC setting was found in the installed SatDump.
    @Published private(set) var agcConfirmed: Set<String> = []
    @Published private(set) var mode: CaptureMode?
    @Published private(set) var snr: Double?
    @Published private(set) var peakSNR: Double?
    @Published private(set) var lockText: String?
    @Published private(set) var bytesWritten: Double?
    @Published private(set) var log: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var outputDir: URL?
    @Published private(set) var startedAt: Date?
    @Published private(set) var detectedDevices: [DetectedDevice] = []
    @Published private(set) var probing = false
    /// The first look for radios has finished, whatever it found. The startup checklist waits on it.
    @Published private(set) var probedOnce = false
    /// The decoders have been checked against upstream at least once this launch.
    @Published private(set) var pipelinesChecked = false
    @Published private(set) var catalog = PipelineCatalog(resourcesDir: nil)

    let spectrum = SpectrumFeed()
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var stopRequested = false
    private var session: SessionInfo?
    private var lastOutput = Date()
    private var processesAfterStop = false
    private var httpPort = 8080
    private static let pidKey = "satdumpChildPID"

    init() {
        killStaleChild()
        locate()
    }

    /// The engine is sealed inside the app and nowhere else. `VESSEL_ENGINE` points a development build,
    /// run outside an app bundle, at the engine in `vendor/satdump`.
    private func locate() {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("Engine/MacOS/vessel-engine").path ?? ""]
        if let dev = ProcessInfo.processInfo.environment["VESSEL_ENGINE"] { candidates.insert(dev, at: 0) }
        executable = candidates.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        catalog = PipelineCatalog(resourcesDir: resourcesDir, updates: acceptedUpdates)
        detectAGC()
    }

    /// Confirms each AGC setting really is in the installed SatDump's plugin for that source, so
    /// the option can't appear for a version that lacks it. Plugins for absent drivers don't count.
    /// Downloaded decoders count only once the override file that the engine reads exists.
    private var acceptedUpdates: URL? {
        FileManager.default.fileExists(atPath: PipelineUpdater.overrideFile.path) ? PipelineUpdater.downloadDir : nil
    }

    /// Runs at every launch, in the background.
    func checkForPipelineUpdates() async {
        defer { pipelinesChecked = true }
        guard let exe = executable else { return }
        pipelineStatus = "Checking for decoder updates…"
        let outcome = await PipelineUpdater.checkForUpdates(engine: exe, installed: resourcesDir?.appendingPathComponent("pipelines"))
        lastPipelineOutcome = outcome
        pipelineStatus = outcome.message
        catalog = PipelineCatalog(resourcesDir: resourcesDir, updates: acceptedUpdates)
    }

    private func detectAGC() {
        guard let e = executable else { agcConfirmed = []; return }
        let plugins = e.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/plugins")
        let specs = SDRCatalog.agc
        Task.detached(priority: .utility) { [weak self] in
            // A build with no plugin folder to inspect can't be checked, so the table stands.
            let inspectable = FileManager.default.fileExists(atPath: plugins.path)
            var found = Set<String>()
            for (id, spec) in specs {
                guard inspectable else { found.insert(id); continue }
                let file = plugins.appendingPathComponent(spec.plugin + ".dylib")
                if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                   data.range(of: Data(spec.marker.utf8)) != nil { found.insert(id) }
            }
            let result = found
            await MainActor.run { [weak self] in self?.agcConfirmed = result }
        }
    }

    private var resourcesDir: URL? {
        guard let e = executable else { return nil }
        let bundled = e.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/resources")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let shared = e.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/satdump")
        return FileManager.default.fileExists(atPath: shared.path) ? shared : nil
    }

    /// Lists attached and network sources. The tool can crash on exit after printing its list,
    /// so its exit status is ignored and only the output is read.
    func probeDevices() {
        guard let exe = executable, !probing else { return }
        probing = true
        Task.detached(priority: .utility) { [weak self] in
            let p = Process()
            p.executableURL = exe
            p.arguments = ["legacy", "sdr_probe"]
            p.currentDirectoryURL = Res.cacheDir
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var devices: [DetectedDevice] = []
            if (try? p.run()) != nil {
                // The engine can hang in its crash handler as it exits, so it's stopped as soon as its list
                // is complete, and after 30 s whatever happens.
                let pid = p.processIdentifier
                let guardTimer = DispatchWorkItem { if p.isRunning { kill(pid, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: guardTimer)
                defer { guardTimer.cancel() }
                var data = Data()
                let reader = out.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if Self.probeFinished(String(decoding: data, as: UTF8.self)) {
                        if p.isRunning { kill(pid, SIGKILL) }
                        break
                    }
                }
                p.waitUntilExit()
                devices = DetectedDevice.parse(Self.stripANSI(String(decoding: data, as: UTF8.self)))
            }
            let found = devices
            await MainActor.run { [weak self] in
                self?.detectedDevices = found
                self?.probing = false
                self?.probedOnce = true
            }
        }
    }

    /// The engine prints its sinks after its sources, then says goodbye: by then the list is all there.
    nonisolated static func probeFinished(_ output: String) -> Bool {
        output.contains("Done! Goodbye") || output.contains("Exiting SatDump")
    }

    nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    func start(_ r: CaptureRequest) {
        guard let exe = executable, !isRunning else { return }
        lastError = nil
        snr = nil; peakSNR = nil; lockText = nil; bytesWritten = nil
        log = []

        httpPort = Int.random(in: 18000...18999)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeLabel = r.label.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        let dir = r.outputDir.appendingPathComponent("\(safeLabel)_\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        processesAfterStop = r.mode == .listen && r.finishProcessing

        var args: [String] = ["legacy"]
        switch r.mode {
        case .listen:
            guard let pipeline = r.pipelineID else { lastError = "No decoder pipeline for this satellite. Use Record."; return }
            // The spectrum gives a signal reading for pipelines whose demodulator reports no SNR.
            args += ["live", pipeline, dir.path, "--fft_enable", "--fft_size", "1024", "--fft_rate", "20", "--fft_avgn", "8"]
        case .record:
            args += ["record", dir.appendingPathComponent("baseband").path, "--baseband_format", r.basebandFormat,
                     "--fft_enable", "--fft_size", "1024", "--fft_rate", "20", "--fft_avgn", "8"]
        }
        args += ["--source", r.source.id,
                 "--samplerate", String(Int64(r.sampleRate)),
                 "--frequency", String(Int64((r.dialHz ?? r.frequencyHz).rounded())),
                 "--http_server", "127.0.0.1:\(httpPort)"]
        if let flag = r.source.addressFlag, let a = r.address, !a.isEmpty { args += ["--\(flag)", a] }
        if r.source.defaultPort != nil, let p = r.port { args += ["--port", String(p)] }
        if let flag = r.source.gainFlag, let g = r.gain { args += ["--\(flag)", String(Int(g))] }
        if let d = r.bitDepth, !r.source.bitDepths.isEmpty { args += ["--bit_depth", String(d)] }
        if r.bias, r.source.hasBias { args += ["--bias"] }
        if r.dcBlock { args += ["--dc_block"] }
        if r.iqSwap { args += ["--iq_swap"] }
        if r.mode == .listen, r.finishProcessing { args += ["--finish_processing"] }
        if r.mode == .listen { args += r.extraArgs }
        args += r.sourceArgs

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        // Its working folder is where it picks up updated decoders.
        p.currentDirectoryURL = PipelineUpdater.runDir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = Self.stripANSI(String(decoding: d, as: UTF8.self))
            Task { @MainActor [weak self] in self?.ingest(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in self?.finished(status: status) }
        }
        do {
            try p.run()
        } catch {
            lastError = "Could not start the decoder: \(error.localizedDescription)"
            return
        }
        process = p
        UserDefaults.standard.set(Int(p.processIdentifier), forKey: Self.pidKey)
        isRunning = true
        mode = r.mode
        outputDir = dir
        startedAt = Date()
        spectrum.begin(frequency: r.frequencyHz, sampleRate: r.sampleRate, mode: r.mode)
        health.begin(frequency: r.frequencyHz, sampleRate: r.sampleRate, mode: r.mode)
        let info = SessionInfo(satellite: r.label, norad: r.norad, frequencyHz: r.frequencyHz, sampleRate: r.sampleRate,
                               pipelineName: r.mode == .listen ? r.pipelineName : nil, decoding: r.mode == .listen,
                               source: r.source.name, host: r.hostLabel, started: Date(), ended: nil, format: r.formatName)
        info.write(to: dir)
        session = info
        appendLog("$ engine " + args.joined(separator: " "))
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        stopRequested = true
        p.interrupt()
        guard processesAfterStop else {
            // SatDump flushes its files on SIGINT, but it can hang after that with a network source.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak p] in
                if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            return
        }
        // Making images can take minutes, so it gets as long as it needs while it's still talking.
        isProcessing = true
        lastOutput = Date()
        Task { [weak self, weak p] in
            while let p, p.isRunning {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if Date().timeIntervalSince(self.lastOutput) > 20, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Must not leave SatDump behind: it would keep recording with nobody to stop it.
    func stopForQuit() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
    }

    /// Clears a SatDump left running by a crash of this app.
    private func killStaleChild() {
        let pid = pid_t(UserDefaults.standard.integer(forKey: Self.pidKey))
        guard pid > 0 else { return }
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
              String(cString: buf).hasSuffix("/satdump") else { return }
        kill(pid, SIGKILL)
    }

    private func finished(status: Int32) {
        spectrum.end()
        health.end()
        isProcessing = false
        if var s = session, let dir = outputDir {
            s.ended = Date()
            s.write(to: dir)
        }
        session = nil
        isRunning = false
        isStreaming = false
        pollTask?.cancel()
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        mode = nil
        snr = nil
        lockText = nil
        // However it ended after being told to stop, that's a normal stop and not a failure.
        let wasStopped = stopRequested
        stopRequested = false
        if !wasStopped && status != 0 && status != SIGINT && status != SIGTERM && lastError == nil {
            lastError = log.last(where: { $0.contains("(E)") || $0.contains("(C)") && !$0.contains("TODOREWORK") })
                ?? "The decoder exited with status \(status)"
        }
    }

    private func ingest(_ text: String) {
        lastOutput = Date()
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            // Skip per-module debug blocks and the banner, which would swamp the short log.
            if s.contains("(T)") || s.contains("(D)") || s.contains("___") || s.contains("/_/")
                || s.contains("Wrote ") || s.contains("Progress") || s.contains("Skipping pipeline") { continue }
            appendLog(s)
            if s.contains("Connection error") || s.contains("Fatal error") || s.contains("Could not find a handler") {
                lastError = Self.branded(s.components(separatedBy: ") ").last ?? s)
            }
        }
    }

    /// The engine is part of this app, so its log speaks in those terms.
    nonisolated static func branded(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "satdump", with: "engine", options: .caseInsensitive)
        t = t.replacingOccurrences(of: "$ engine legacy ", with: "$ engine ")
        return t
    }

    private func appendLog(_ raw: String) {
        let s = Self.branded(raw)
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func pollLoop() async {
        var gotStats = false
        let began = Date()
        let url = URL(string: "http://127.0.0.1:\(httpPort)/api")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // SatDump opens its stats port only once the source streams, so silence means it is stuck.
                if !gotStats, Date().timeIntervalSince(began) > 40, !Task.isCancelled {
                    stop()
                    lastError = "The signal didn't start streaming in 40 s."
                    return
                }
                continue
            }
            gotStats = true
            isStreaming = true
            apply(json)
        }
    }

    private func apply(_ json: [String: Any]) {
        // SatDump can report a value that JSON spells as null, which counts as no signal in that bin.
        let fft = (json["fft_values"] as? [Any])?.map { ($0 as? NSNumber)?.floatValue ?? -200 } ?? []
        spectrum.update(fft)
        if let found = Self.find(key: "snr", in: json) {
            snr = found
            peakSNR = Self.find(key: "peak_snr", in: json)
        } else if fft.count > 8 {
            snr = Self.spectrumSNR(fft)
            peakSNR = max(peakSNR ?? 0, snr ?? 0)
        }
        if let w = (json["written_raw"] as? NSNumber)?.doubleValue { bytesWritten = w }
        lockText = Self.lockState(json)
        // Frames only: a Viterbi "lock" can read as locked before any samples have arrived.
        health.update(fft: fft, framesLocked: Self.findBool(key: "deframer_lock", in: json) == true)
    }

    /// With no demodulator figure: the strongest bins above the median floor. Plain noise already shows a
    /// few dB of peak over median, so that margin is taken off. The middle is left out, as most receivers
    /// have a spike of their own there that stands out more the lower the gain, which made the reading
    /// fall as gain rose. The edges are left out too, being only filter roll-off.
    nonisolated static func spectrumSNR(_ fft: [Float]) -> Double {
        let n = fft.count
        let edge = n / 10, centre = n / 2, guardBins = max(2, n / 256)
        let bins = fft.indices.filter { $0 >= edge && $0 < n - edge && abs($0 - centre) > guardBins }.map { Double(fft[$0]) }.sorted()
        guard bins.count > 8 else { return 0 }
        let top = bins.suffix(3).reduce(0, +) / 3
        return max(0, top - bins[bins.count / 2] - 4)
    }

    private static func find(key: String, in d: [String: Any]) -> Double? {
        if let v = (d[key] as? NSNumber)?.doubleValue { return v }
        for value in d.values {
            if let sub = value as? [String: Any], let v = find(key: key, in: sub) { return v }
        }
        return nil
    }

    private static func findBool(key: String, in d: [String: Any]) -> Bool? {
        if let v = d[key] as? NSNumber { return v.boolValue }
        for value in d.values {
            if let sub = value as? [String: Any], let v = findBool(key: key, in: sub) { return v }
        }
        return nil
    }

    private static func lockState(_ d: [String: Any]) -> String? {
        if let f = findBool(key: "deframer_lock", in: d) { return f ? "Frames locked" : "Searching for frames" }
        if let v = findBool(key: "viterbi_lock", in: d) { return v ? "Viterbi locked" : "Searching" }
        return nil
    }
}
