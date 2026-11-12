import Foundation
import Network

/// Working out where you are from the GPS satellites themselves, for when there's nothing else: records
/// the GPS L1 band with your own receiver, then has GNSS-SDR turn the recording into positions.
enum GPSFixPlan {
    static let l1Hz = 1_575_420_000.0
    static let bytesPerSample = 4.0 // cs16: 16 bits each of I and Q
    static let durations = [120, 300]
    /// A receiver needs about 30 seconds of a satellite's message for its orbit, and four satellites.
    static let defaultDuration = 120
    static let processingLimit: TimeInterval = 30 * 60

    /// GNSS-SDR ships inside the app, so this works with nothing installed and no internet.
    static func findGNSSSDR(in resources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let path = resources?.appendingPathComponent("GNSS/bin/gnss-sdr"),
              FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        return path
    }

    /// The receiver as it's set up in Listener.
    struct Receiver: Equatable {
        var source: SDRSource
        var address: String? = nil
        var port: Int? = nil
        var sampleRate: Double
        /// Nil leaves it to the receiver's own automatic gain.
        var gain: Double? = nil
        var bias = false
        var bitDepth: Int? = nil
        var sourceArgs: [String] = []
    }

    enum Readiness: Equatable {
        case ready
        /// What's wrong, in words that say what to do about it in Listener.
        case needsSource(String)
    }

    /// Whether what's chosen in Listener can do this. Any receiver of your own can, wherever it's connected.
    static func readiness(source: SDRSource, address: String, connectedDevice: String?, listenerRate: Double) -> Readiness {
        let choose = "Please choose a source in Listener."
        guard !source.browserOnly else { return .needsSource("\(source.name) only plays in a browser. \(choose)") }
        // Its signal is what the station hears, so the answer would be where the station is, not where you are.
        guard source.kind != .spy else {
            return .needsSource("\(source.name) is someone else's station, so GPS would find them instead of you. Please choose your own receiver in Listener.")
        }
        if let ranges = SDRCatalog.tunableRanges(source.id), !ranges.contains(where: { $0.contains(l1Hz) }) {
            return .needsSource("\(source.name) can't receive GPS, at 1,575.42 MHz. \(choose)")
        }
        if source.addressFlag != nil, address.trimmingCharacters(in: .whitespaces).isEmpty {
            return .needsSource("\(source.name) has no address yet. Enter it in Listener, or choose another source.")
        }
        if takesRateFromServer(source), listenerRate < minimumRate {
            return .needsSource("GPS needs at least 2 MS/s, and \(source.name) is set lower. Raise its sample rate in Capture.")
        }
        if source.kind == .usb, connectedDevice == nil {
            return .needsSource("No \(source.name) is plugged in. Plug it in, or choose a source in Listener.")
        }
        return .ready
    }

    static let minimumRate = 2_000_000.0

    /// These send whatever their server is set to, which is what the Sample rate in Capture has to say.
    static func takesRateFromServer(_ source: SDRSource) -> Bool {
        source.id == "sdrpp_server" || source.id == "net_source"
    }

    static func sampleRate(for source: SDRSource, listenerRate: Double) -> Double {
        if takesRateFromServer(source) { return listenerRate }
        switch source.id {
        // These only offer a few rates, and 3 MHz is the lowest that holds the whole signal.
        case "airspy", "hydrasdr": return 3_000_000
        default: return minimumRate
        }
    }

    /// GPS sits below the noise, so most of the gain is needed, with some left to avoid overload.
    static func gain(for source: SDRSource) -> Double {
        source.gainRange.lowerBound + (source.gainRange.upperBound - source.gainRange.lowerBound) * 0.8
    }

    static func recordingBytes(rate: Double, seconds: Int) -> Double { rate * bytesPerSample * Double(seconds) }

    static func engineArguments(_ r: Receiver, output: String, seconds: Int) -> [String] {
        var args = ["legacy", "record", output, "--baseband_format", "cs16", "--source", r.source.id,
                    "--samplerate", String(Int64(r.sampleRate)), "--frequency", String(Int64(l1Hz)),
                    "--timeout", String(seconds), "--dc_block"]
        if let flag = r.source.addressFlag, let a = r.address, !a.isEmpty { args += ["--\(flag)", a] }
        if r.source.defaultPort != nil, let p = r.port { args += ["--port", String(p)] }
        if let flag = r.source.gainFlag, let g = r.gain { args += ["--\(flag)", String(Int(g))] }
        if let depth = r.bitDepth, !r.source.bitDepths.isEmpty { args += ["--bit_depth", String(depth)] }
        if r.bias, r.source.hasBias { args.append("--bias") }
        return args + r.sourceArgs
    }

    /// Its logs go in the working folder too, so they're deleted along with the recording.
    static func processingArguments(config: String, logFolder: String) -> [String] {
        ["--config_file=\(config)", "--log_dir=\(logFolder)"]
    }

    /// Based on GNSS-SDR's own GPS L1 file example, for a single fix with nothing known in advance.
    static func configuration(recording: String, rate: Double, outputFolder: String) -> String {
        let fs = String(Int64(rate))
        return """
        [GNSS-SDR]
        GNSS-SDR.internal_fs_sps=\(fs)
        ControlThread.wait_for_flowgraph=false
        SignalSource.implementation=File_Signal_Source
        SignalSource.filename=\(recording)
        SignalSource.item_type=ishort
        SignalSource.sampling_frequency=\(fs)
        SignalSource.samples=0
        SignalSource.repeat=false
        SignalSource.dump=false
        SignalSource.enable_throttle_control=false
        SignalConditioner.implementation=Signal_Conditioner
        DataTypeAdapter.implementation=Ishort_To_Complex
        InputFilter.implementation=Pass_Through
        InputFilter.input_item_type=gr_complex
        InputFilter.output_item_type=gr_complex
        Resampler.implementation=Pass_Through
        Resampler.item_type=gr_complex
        Channels_1C.count=8
        Channels.in_acquisition=1
        Channel.signal=1C
        Acquisition_1C.implementation=GPS_L1_CA_PCPS_Acquisition
        Acquisition_1C.item_type=gr_complex
        Acquisition_1C.coherent_integration_time_ms=1
        Acquisition_1C.pfa=0.01
        Acquisition_1C.doppler_max=10000
        Acquisition_1C.doppler_step=250
        Acquisition_1C.dump=false
        Acquisition_1C.blocking=false
        Tracking_1C.implementation=GPS_L1_CA_DLL_PLL_Tracking
        Tracking_1C.item_type=gr_complex
        Tracking_1C.pll_bw_hz=40.0
        Tracking_1C.dll_bw_hz=4.0
        Tracking_1C.order=3
        Tracking_1C.dump=false
        TelemetryDecoder_1C.implementation=GPS_L1_CA_Telemetry_Decoder
        TelemetryDecoder_1C.dump=false
        Observables.implementation=Hybrid_Observables
        Observables.dump=false
        PVT.implementation=RTKLIB_PVT
        PVT.positioning_mode=Single
        PVT.iono_model=Broadcast
        PVT.trop_model=Saastamoinen
        PVT.output_rate_ms=100
        PVT.display_rate_ms=500
        PVT.dump=false
        PVT.output_path=\(outputFolder)
        PVT.geojson_output_enabled=true
        PVT.kml_output_enabled=false
        PVT.gpx_output_enabled=false
        PVT.nmea_output_file_enabled=false
        PVT.rinex_output_enabled=false
        PVT.rtcm_output_file_enabled=false
        PVT.xml_output_enabled=false

        """
    }

    struct Point: Equatable {
        let longitude: Double
        let latitude: Double
        let height: Double
    }

    /// Reads "[lon, lat, height]" rows directly, as a stopped run leaves the file without its ending.
    static func points(inGeoJSON text: String) -> [Point] {
        guard let pattern = try? NSRegularExpression(pattern: #"\[\s*(-?[0-9.eE+-]+)\s*,\s*(-?[0-9.eE+-]+)\s*,\s*(-?[0-9.eE+-]+)\s*\]"#) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { m in
            guard let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text), let c = Range(m.range(at: 3), in: text),
                  let lon = Double(text[a]), let lat = Double(text[b]), let h = Double(text[c]) else { return nil }
            return Point(longitude: lon, latitude: lat, height: h)
        }
    }

    struct Fix: Equatable {
        let latitude: Double
        let longitude: Double
        let height: Double
        /// Metres that 95% of the readings fall inside.
        let spread: Double
        let readings: Int
        /// How many satellites the position was worked out from, and how many were heard at all.
        var satellitesUsed: Int? = nil
        var satellitesHeard: Int? = nil

        /// What might make this position less trustworthy, to see before pinning it.
        var warnings: [String] {
            var out: [String] = []
            if let used = satellitesUsed, used <= minimumSatellites {
                out.append("Only \(used) satellites were used, the fewest that can give a position, so it may be well off.")
            }
            if spread > 100 {
                out.append("Readings varied by about \(LocationNote.within(spread).replacingOccurrences(of: "within about ", with: "")), so the signal was weak or blocked.")
            }
            if readings < 30 {
                out.append("Only \(readings) readings came through. A longer scan would be steadier.")
            }
            return out
        }
    }

    /// Latitude, longitude, height and time.
    static let minimumSatellites = 4

    /// "Position at … using 5 observations is Lat = …".
    static func observations(inLine line: String) -> Int? {
        guard let r = line.range(of: #"using [0-9]+ observations"#, options: .regularExpression) else { return nil }
        return Int(line[r].dropFirst(6).prefix { $0.isNumber })
    }

    /// The line that says what went wrong, without the noise around it.
    static func errorText(inLine raw: String) -> String? {
        let line = SatDumpRunner.stripANSI(raw).trimmingCharacters(in: .whitespaces)
        // Always logged, and only means SDRplay's service isn't installed.
        guard !line.contains("SDRPlay") else { return nil }
        if let r = line.range(of: "(E) ") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        if line.contains("Unable to") || line.range(of: #"^E[0-9]{4} "#, options: .regularExpression) != nil {
            return line.range(of: #"\] "#, options: .regularExpression).map { String(line[$0.upperBound...]) } ?? line
        }
        return nil
    }

    /// The middle of the readings, leaving out the first ones while the solution settles, and any that are impossible.
    static func fix(from all: [Point]) -> Fix? {
        let valid = all.filter { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 && abs($0.height) < 20_000 && ($0.latitude != 0 || $0.longitude != 0) }
        let settled = Array(valid.dropFirst(valid.count / 10))
        guard settled.count >= 3 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let lat = median(settled.map(\.latitude))
        // The middle of longitudes either side of 180° would be on the wrong side of the world.
        let reference = settled[0].longitude
        let unwrapped = settled.map { p -> Double in
            var d = p.longitude - reference
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            return reference + d
        }
        var lon = median(unwrapped)
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        let height = median(settled.map(\.height))
        let metresPerDegree = 111_320.0
        let scale = cos(lat * .pi / 180)
        let distances = zip(settled, unwrapped).map { p, u -> Double in
            let dy = (p.latitude - lat) * metresPerDegree
            let dx = (u - (lon < reference - 180 ? lon + 360 : lon > reference + 180 ? lon - 360 : lon)) * metresPerDegree * scale
            return (dx * dx + dy * dy).squareRoot()
        }.sorted()
        return Fix(latitude: lat, longitude: lon, height: height,
                   spread: distances[min(distances.count - 1, Int(Double(distances.count) * 0.95))], readings: settled.count)
    }

    /// "Tracking of GPS L1 C/A signal started on channel 4 for satellite GPS PRN 21 (Block IIR-M)".
    static func satellite(inLine line: String) -> Int? {
        guard line.contains("Tracking of GPS"), line.contains("started"),
              let r = line.range(of: #"PRN\s*[0-9]+"#, options: .regularExpression) else { return nil }
        return Int(line[r].dropFirst(3).trimmingCharacters(in: .whitespaces))
    }
}

/// Runs a fix from start to finish, for the popup to show. Only one at a time.
@MainActor
final class GPSFixController: ObservableObject {
    enum Stage: Equatable {
        case ready
        case recording(elapsed: Int, total: Int)
        case processing(satellites: Int, positioned: Bool)
        case found(GPSFixPlan.Fix)
        case failed(String)
    }

    @Published private(set) var stage = Stage.ready
    /// For saying how close a failed scan came, and in the program's own words why it stopped.
    @Published private(set) var satellitesHeard = 0
    @Published private(set) var failureDetail: String?

    var isBusy: Bool {
        switch stage {
        case .recording, .processing: return true
        default: return false
        }
    }

    private var process: Process?
    private var cancelled = false
    private var job: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private let workRoot: URL

    /// The temporary folder, as GNSS-SDR cuts long file paths short without saying so, and has no use for spaces.
    init(workRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("gpsfix")) {
        self.workRoot = workRoot
        // A recording left by a crash can be gigabytes.
        try? FileManager.default.removeItem(at: workRoot)
    }

    func reset() { if !isBusy { stage = .ready } }

    /// For checking each screen without a scan.
    func show(_ stage: Stage, heard: Int = 0, detail: String? = nil) {
        self.stage = stage
        satellitesHeard = heard
        failureDetail = detail
    }

    func start(_ receiver: GPSFixPlan.Receiver, seconds: Int, engine: URL?, gnssSDR: URL?, engineFolder: URL? = nil) {
        guard !isBusy else { return }
        guard let engine else { stage = .failed("The receiver engine is missing."); return }
        guard let gnssSDR else { stage = .failed("This copy of Vessel was built without its GPS processor."); return }
        let rate = receiver.sampleRate
        let needed = GPSFixPlan.recordingBytes(rate: rate, seconds: seconds)
        try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        if let free = (try? workRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           Double(free) < needed * 1.2 {
            stage = .failed("This needs \(ByteCountFormatter.string(fromByteCount: Int64(needed * 1.2), countStyle: .file)) of free disk space for the recording.")
            return
        }
        cancelled = false
        satellitesHeard = 0
        failureDetail = nil
        // Sleeping halfway would ruin the recording.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Finding a GPS position")
        stage = .recording(elapsed: 0, total: seconds)
        job = Task { [weak self] in
            await self?.run(receiver, seconds: seconds, engine: engine, gnssSDR: gnssSDR, engineFolder: engineFolder, rate: rate, needed: needed)
        }
    }

    func cancel() {
        cancelled = true
        if let p = process, p.isRunning { p.terminate() }
        job?.cancel()
    }

    private func run(_ receiver: GPSFixPlan.Receiver, seconds: Int, engine: URL, gnssSDR: URL, engineFolder: URL?, rate: Double, needed: Double) async {
        let work = workRoot.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        defer {
            // A recording is only a means to the position, and takes up a lot of room.
            try? FileManager.default.removeItem(at: work)
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            process = nil
            job = nil
        }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            stage = .failed("Couldn't make a folder for the recording.")
            return
        }

        // 1. Record.
        var engineErrors: [String] = []
        let clock = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled, elapsed < seconds {
                try? await Task.sleep(for: .seconds(1))
                elapsed += 1
                if case .recording = self?.stage { self?.stage = .recording(elapsed: elapsed, total: seconds) }
            }
        }
        _ = await runProcess(engine, GPSFixPlan.engineArguments(receiver, output: work.appendingPathComponent("gps").path, seconds: seconds),
                             folder: engineFolder ?? work, limit: TimeInterval(seconds + 30)) { line in
            if let text = GPSFixPlan.errorText(inLine: line) { engineErrors.append(text) }
        }
        clock.cancel()
        guard !cancelled else { stage = .ready; return }

        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let sized = files.map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        guard let recording = sized.max(by: { $0.size < $1.size }), Double(recording.size) >= needed * 0.5 else {
            let check = receiver.source.kind == .network ? "Check that it can be reached" : "Check that it's plugged in"
            failureDetail = engineErrors.last
            stage = .failed("\(receiver.source.name) didn't record enough signal. \(check) and that nothing else is using it.")
            return
        }

        // 2. Turn it into positions.
        stage = .processing(satellites: 0, positioned: false)
        let output = work.appendingPathComponent("positions", isDirectory: true)
        let config = work.appendingPathComponent("gps.conf")
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try GPSFixPlan.configuration(recording: recording.url.path, rate: rate, outputFolder: output.path).write(to: config, atomically: true, encoding: .utf8)
        } catch {
            stage = .failed("Couldn't prepare the GPS processing.")
            return
        }
        var seen = Set<Int>()
        var positioned = false
        var used: [Int] = []
        var processErrors: [String] = []
        let status = await runProcess(gnssSDR, GPSFixPlan.processingArguments(config: config.path, logFolder: work.path), folder: work, limit: GPSFixPlan.processingLimit) { [weak self] line in
            if let prn = GPSFixPlan.satellite(inLine: line) { seen.insert(prn) }
            if line.contains("position fix") { positioned = true }
            if let n = GPSFixPlan.observations(inLine: line) { used.append(n) }
            if let text = GPSFixPlan.errorText(inLine: line) { processErrors.append(text) }
            self?.satellitesHeard = seen.count
            if case .processing = self?.stage { self?.stage = .processing(satellites: seen.count, positioned: positioned) }
        }
        guard !cancelled else { stage = .ready; return }

        // 3. Read the GeoJSON it wrote, which it can put either in that folder or beside the recording.
        let enumerator = FileManager.default.enumerator(at: work, includingPropertiesForKeys: nil)
        var points: [GPSFixPlan.Point] = []
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "geojson", let text = try? String(contentsOf: file, encoding: .utf8) {
                points += GPSFixPlan.points(inGeoJSON: text)
            }
        }
        // Output lines arrive just after the program ends.
        try? await Task.sleep(for: .milliseconds(200))
        satellitesHeard = seen.count
        failureDetail = processErrors.last
        if var fix = GPSFixPlan.fix(from: points) {
            fix.satellitesUsed = used.isEmpty ? nil : used.sorted()[used.count / 2]
            fix.satellitesHeard = seen.isEmpty ? nil : seen.count
            stage = .found(fix)
        } else if status == -1 {
            stage = .failed("The GPS processor couldn't be started.")
        } else if seen.isEmpty {
            stage = .failed("No GPS satellites were heard. Check that the antenna can see open sky and that an active antenna has power.")
        } else {
            stage = .failed("Heard \(seen.count) satellite\(seen.count == 1 ? "" : "s"), but a position needs \(GPSFixPlan.minimumSatellites) with a clean signal for long enough. Try a longer recording with a clearer view of the sky.")
        }
    }

    /// Returns the exit status, or -1 if it couldn't start. Stops it at the limit, whatever it's doing.
    private func runProcess(_ exe: URL, _ args: [String], folder: URL, limit: TimeInterval, onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = folder
        // Answers rather than waits, if it ever asks for a key.
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let reader = LineReader(onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in reader.feed(h.availableData) }
        return await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            p.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                reader.feed(pipe.fileHandleForReading.availableData)
                c.resume(returning: finished.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                c.resume(returning: -1)
                return
            }
            process = p
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak p] in
                if let p, p.isRunning { p.terminate() }
            }
        }
    }
}

/// Splits a program's output into lines, however it arrives.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @MainActor (String) -> Void

    init(_ onLine: @escaping @MainActor (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...end)
        }
        lock.unlock()
        guard !lines.isEmpty else { return }
        let onLine = onLine
        Task { @MainActor in lines.forEach(onLine) }
    }
}

/// Whether there's Wi-Fi or any other way out right now.
enum NetworkStatus {
    struct Now: Equatable { let wifi: Bool; let internet: Bool }

    static func check() async -> Now {
        await withCheckedContinuation { c in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                monitor.pathUpdateHandler = nil
                let up = path.status == .satisfied
                c.resume(returning: Now(wifi: up && path.usesInterfaceType(.wifi), internet: up))
            }
            monitor.start(queue: DispatchQueue(label: "network-status"))
        }
    }
}

/// A position kept in the address search until it's removed.
struct SavedLocation: Codable, Identifiable, Equatable {
    var id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let iso: String
    let saved: Date
    var height: Double?
    var spread: Double?

    /// "12.34567, -45.67890", the way Google Maps writes and reads them. Five places is about a metre,
    /// and anything finer isn't real here.
    static func coordinates(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    static func googleMapsURL(latitude: Double, longitude: Double) -> URL? {
        URL(string: String(format: "https://www.google.com/maps?q=%.6f,%.6f", latitude, longitude))
    }

    static func load(from defaults: UserDefaults = .standard) -> [SavedLocation] {
        defaults.data(forKey: "savedLocations").flatMap { try? JSONDecoder().decode([SavedLocation].self, from: $0) } ?? []
    }

    static func store(_ list: [SavedLocation], in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: "savedLocations") }
    }
}
