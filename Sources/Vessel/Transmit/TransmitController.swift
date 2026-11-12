import SwiftUI
import AppKit
import CoreAudio

enum RadioKind: String, CaseIterable, Identifiable {
    case detected = "USB radio (found automatically)"
    case hamlib = "Real radio (rigctld)"
    var id: String { rawValue }
}

enum RadioState: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

/// Keys and unkeys the radio. Every path to the transmitter goes through `press()`, and
/// `tick()` re-checks the conditions four times a second for as long as it stays keyed.
@MainActor
final class TransmitController: ObservableObject {
    // Station settings, kept between launches.
    @Published var callsign = UserDefaults.standard.string(forKey: "tx.callsign") ?? "" {
        didSet { UserDefaults.standard.set(callsign, forKey: "tx.callsign") }
    }
    @Published var licenceConfirmed = UserDefaults.standard.bool(forKey: "tx.licence") {
        didSet { UserDefaults.standard.set(licenceConfirmed, forKey: "tx.licence") }
    }
    @Published var minElevation = UserDefaults.standard.object(forKey: "tx.minElevation") as? Double ?? 10 {
        didSet { UserDefaults.standard.set(minElevation, forKey: "tx.minElevation") }
    }
    @Published var timeoutSeconds = UserDefaults.standard.object(forKey: "tx.timeout") as? Double ?? 120 {
        didSet { UserDefaults.standard.set(timeoutSeconds, forKey: "tx.timeout") }
    }
    @Published var rigPort = UserDefaults.standard.object(forKey: "tx.rigPort") as? Int ?? 4532 {
        didSet { UserDefaults.standard.set(rigPort, forKey: "tx.rigPort") }
    }
    @Published var positionPrecision = APRSPosition.Precision(rawValue: UserDefaults.standard.string(forKey: "tx.positionPrecision") ?? "") ?? .about2km {
        didSet { UserDefaults.standard.set(positionPrecision.rawValue, forKey: "tx.positionPrecision") }
    }
    @Published var positionComment = UserDefaults.standard.string(forKey: "tx.positionComment") ?? "" {
        didSet { UserDefaults.standard.set(positionComment, forKey: "tx.positionComment") }
    }
    /// The report to send, from your own location. Never a public host's, which is only borrowed.
    var positionReport: String? {
        guard let s = app.station, !s.fromSpyHost else { return nil }
        return APRSPosition.info(lat: s.lat, lon: s.lon, precision: positionPrecision, comment: positionComment)
    }
    /// What actually goes out in the current mode.
    private var outgoing: String { mode == .aprsPosition ? positionReport ?? "" : message }

    @Published var message = UserDefaults.standard.string(forKey: "tx.message") ?? "" {
        didSet { UserDefaults.standard.set(message, forKey: "tx.message") }
    }

    @Published var radioKind: RadioKind = .detected { didSet { if radioKind != oldValue { disconnect() } } }
    @Published private(set) var radio: RadioState = .disconnected

    @Published private(set) var uplinks: [Uplink] = []
    @Published var uplink: Uplink? { didSet { uplinkChanged() } }
    @Published var mode: TxMode?
    @Published var passbandPosition = 0.5
    /// nil means the radio's own microphone carries voice.
    @Published var audioDevice: AudioOutput?
    @Published var outputs: [AudioOutput] = []

    @Published private(set) var isKeyed = false
    @Published private(set) var isPressing = false
    @Published private(set) var keyedAt: Date? {
        didSet { app.transmitKeyed = keyedAt != nil }
    }
    @Published private(set) var txHz: Double?
    @Published private(set) var signalHz: Double?
    @Published private(set) var waitingForSlot = false
    @Published private(set) var rxHz: Double?
    @Published private(set) var dopplerHz: Double?
    @Published private(set) var uplinkConfirmed = false
    @Published private(set) var lastEvent: String?
    @Published private(set) var alarm: String?
    @Published private(set) var checks: [TxChecks.Item] = []
    @Published private(set) var canTransmit = false

    /// Lowered only by the self-test, which runs on a Mac with real speakers.
    var outputVolume: Float = 1

    private unowned let app: AppState
    private let tuneLink = RigLink(label: "tune")
    /// Its own connection, so that unkeying never waits behind a tuning command.
    private let pttLink = RigLink(label: "ptt")
    private let audio = AudioRouter()
    private var rigDaemon: Process?
    private var guardProcess: Process?
    private var guardPipe: Pipe?
    private var activePort = 0
    private var ticker: Timer?
    private var tickCount = 0
    private var sat: Satellite?
    private var elevation: Double?
    private var rangeRate: Double?
    private var appliedModeKey = ""
    private var tuning = false
    private var logEntry: TxLog.Entry?
    private var observer: NSObjectProtocol?
    private var problemKey = ""
    private var cachedProblem: String?
    /// Each press gets its own number, so a slow start can't act on a later press.
    private var pressToken = 0

    init(app: AppState) {
        self.app = app
        outputs = AudioRouter.outputs()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A hold can't be trusted once the app loses the mouse.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPressing == true { self?.release("App lost focus") } }
        }
    }

    var isRadioConnected: Bool { radio == .connected }

    // MARK: Satellite

    func satelliteChanged(_ s: Satellite?) {
        if isPressing { release("Satellite changed") }
        sat = s?.clone()
        refreshUplinks(s)
    }

    func refreshUplinks(_ s: Satellite?) {
        let list = s.map(UplinkPolicy.uplinks) ?? []
        guard list != uplinks else { return }
        uplinks = list
        if uplink == nil || !list.contains(uplink!) { uplink = list.first { !$0.modes.isEmpty } ?? list.first }
    }

    private func uplinkChanged() {
        if isPressing { release("Uplink changed") }
        passbandPosition = 0.5
        if let m = mode, uplink?.modes.contains(m) == true { return }
        mode = uplink?.modes.first
    }

    // MARK: Radio connection

    static let rigctldPaths = ["/opt/homebrew/bin/rigctld", "/usr/local/bin/rigctld"]
    static var rigctld: String? { rigctldPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    // MARK: Finding a radio

    @Published private(set) var foundRadio: FoundRadio?
    @Published private(set) var isSearchingForRadio = false
    @Published private(set) var radioSearchText = "Looking for a radio on USB…"
    private var triedPorts = Set<String>()

    /// Asks anything newly plugged in what it is. Read-only, and it never connects by itself:
    /// the radio only becomes the selected one, ready for Connect.
    func searchForRadios(force: Bool = false) {
        guard !isSearchingForRadio, !isRadioConnected else { return }
        let ports = RadioFinder.ports()
        if let found = foundRadio, !ports.contains(found.port) {
            foundRadio = nil
        }
        triedPorts.formIntersection(ports)
        if force { triedPorts = []; foundRadio = nil }
        let fresh = ports.filter { !triedPorts.contains($0) }
        guard !fresh.isEmpty else {
            if foundRadio == nil, ports.isEmpty { radioSearchText = "No radio found on USB. Plug one in and it'll appear here." }
            return
        }
        isSearchingForRadio = true
        radioSearchText = "Asking \(fresh.count == 1 ? "a USB device" : "\(fresh.count) USB devices") what it is…"
        triedPorts.formUnion(fresh)
        Task {
            let result = await Task.detached(priority: .utility) { fresh.lazy.compactMap(RadioFinder.probe).first }.value
            isSearchingForRadio = false
            if let result {
                foundRadio = result
                radioSearchText = "\(result.name) on \(result.port.replacingOccurrences(of: "/dev/cu.", with: ""))"
            } else if foundRadio == nil {
                radioSearchText = "A USB device is plugged in, but it didn't answer as a known radio. If it is one, start rigctld and choose Real radio."
            }
        }
    }

    /// Runs Hamlib for the radio that was found, with the lines that can key a radio held off.
    private func startDetected(_ radio: FoundRadio) throws -> Int {
        guard let path = Self.rigctld else { throw RigError(message: "Hamlib isn't installed. Run: brew install hamlib") }
        let rigctl = path.replacingOccurrences(of: "rigctld", with: "rigctl")
        guard let model = RadioFinder.hamlibModel(named: radio.name, in: RadioFinder.hamlibList(rigctl: rigctl)) else {
            throw RigError(message: "Hamlib doesn't know the \(radio.name). Start rigctld by hand and choose Real radio.")
        }
        let port = Int.random(in: 19000...19999)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-m", String(model), "-r", radio.port, "-s", String(radio.baud), "--set-conf=rts_state=OFF,dtr_state=OFF",
                       "-T", "127.0.0.1", "-t", String(port)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        rigDaemon = p
        return port
    }

    func connect() {
        guard radio != .connecting else { return }
        radio = .connecting
        Task {
            do {
                var port = rigPort
                if radioKind == .detected {
                    guard let found = foundRadio else { throw RigError(message: "No USB radio found. Plug one in, or choose Real radio if rigctld is running.") }
                    port = try startDetected(found)
                }
                // Hamlib needs a moment before it listens, when started from here.
                var lastError: Error?
                for _ in 0..<20 {
                    do {
                        try await tuneLink.connect(port: port)
                        try await pttLink.connect(port: port)
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        if radioKind == .hamlib { break }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                if let lastError { throw lastError }
                // Whatever state the radio was left in, start out receiving.
                try await pttLink.set("T 0")
                activePort = port
                startGuard(port: port)
                appliedModeKey = ""
                radio = .connected
            } catch {
                stopRigDaemon()
                radio = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        if isPressing { release("Radio disconnected") }
        tuneLink.disconnect()
        pttLink.disconnect()
        stopGuard()
        stopRigDaemon()
        uplinkConfirmed = false
        txHz = nil; signalHz = nil; rxHz = nil; dopplerHz = nil
        radio = .disconnected
    }

    private func stopRigDaemon() {
        rigDaemon?.terminate()
        rigDaemon = nil
    }

    /// A small shell process that holds a pipe to this app. If the app dies for any reason,
    /// even a crash or `kill -9`, the pipe closes and it unkeys the radio.
    private func startGuard(port: Int) {
        stopGuard()
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        var script = "cat >/dev/null; for i in 1 2 3; do printf 'T 0\\n' | /usr/bin/nc -w 1 127.0.0.1 \(port) >/dev/null 2>&1 && break; sleep 0.2; done"
        if let sim = rigDaemon { script += "; kill \(sim.processIdentifier) 2>/dev/null" }
        p.arguments = ["-c", script]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            guardProcess = p
            guardPipe = pipe
        } catch {
            radio = .failed("Could not start the transmit guard")
        }
    }

    private func stopGuard() {
        try? guardPipe?.fileHandleForWriting.close()
        guardPipe = nil
        guardProcess = nil
    }

    /// Runs on quit. The guard covers anything this misses.
    func shutdown() {
        audio.stop()
        if isRadioConnected { pttLink.setBlocking("T 0") }
        stopGuard()
        stopRigDaemon()
    }

    // MARK: Periodic work

    private func updatePointing() {
        guard let st = app.station, let s = sat else { elevation = nil; rangeRate = nil; return }
        let jd = Astro.julianDate()
        func look(_ t: Double) -> (az: Double, el: Double, range: Double)? {
            guard let state = s.state(jd: t) else { return nil }
            return Astro.lookAngles(target: Astro.ecef(state.r, gmst: Astro.gmst(t)), latDeg: st.lat, lonDeg: st.lon)
        }
        guard let a = look(jd), let b = look(jd + 1.0 / 86400) else { elevation = nil; rangeRate = nil; return }
        elevation = a.el
        rangeRate = b.range - a.range
    }

    /// nil when ready. Worked out once per message: FT8 packing is quick but this runs four times a second.
    private var audioProblem: String? {
        guard let mode else { return "No mode" }
        if mode.isVoice { return nil }
        if audioDevice == nil { return "Choose an audio output" }
        let key = "\(mode.rawValue)|\(callsign)|\(outgoing)"
        if key != problemKey {
            problemKey = key
            cachedProblem = TxSignal.problem(mode: mode, message: outgoing, callsign: callsign)
        }
        return cachedProblem
    }

    /// The usual calling message for FT8 and FT4, from your callsign and location.
    var ftxCallingMessage: String {
        let call = callsign.split(separator: "-").first.map(String.init) ?? "YOURCALL"
        let grid = app.station.flatMap { $0.fromSpyHost ? nil : Maidenhead.locator(lat: $0.lat, lon: $0.lon) } ?? "GRID"
        return "CQ \(call) \(grid)"
    }

    private func currentChecks() -> TxChecks {
        TxChecks(callsign: callsign, licenceConfirmed: licenceConfirmed, sourceKind: app.source.kind, station: app.station,
                 radioConnected: isRadioConnected && uplinkConfirmed, uplink: uplink, mode: mode, elevation: elevation,
                 minElevation: minElevation, elementAgeDays: sat.map { Astro.julianDate() - $0.epochJD },
                 audioReady: audioProblem == nil, audioDetail: audioProblem)
    }

    func tick() {
        tickCount += 1
        updatePointing()
        let c = currentChecks()
        let items = c.items
        if items != checks { checks = items }
        if c.allPass != canTransmit { canTransmit = c.allPass }

        if isPressing {
            if let keyedAt, Date().timeIntervalSince(keyedAt) >= timeoutSeconds {
                release("Timeout reached")
            } else if !c.allPass {
                release(c.firstFailure.map { "\($0.id): \($0.detail)" } ?? "Check failed")
            }
        }
        if tickCount % 4 == 0 {
            trackRadio()
            if isKeyed { confirmStillKeyed() }
        }
    }

    /// Follows Doppler once a second. Failures here read as a lost radio, which also drops any transmission.
    private func trackRadio() {
        guard isRadioConnected, !tuning else { return }
        guard let u = uplink, let rr = rangeRate else {
            if uplinkConfirmed { uplinkConfirmed = false }
            return
        }
        tuning = true
        Task {
            defer { tuning = false }
            do { try await applyTuning(u, rangeRate: rr) }
            catch { radioLost(error) }
        }
    }

    private func applyTuning(_ u: Uplink, rangeRate rr: Double) async throws {
        // Doppler applies to where the signal really is, and the dial follows from that.
        let nominalTx = u.signalHz(position: passbandPosition, mode: mode)
        let nominalDial = u.dialHz(position: passbandPosition, mode: mode)
        let nominalRx = u.downlinkHz(position: passbandPosition, mode: mode)
        let tx = (Doppler.uplink(nominalDial, rangeRate: rr) / 10).rounded() * 10
        let rx = (Doppler.downlink(nominalRx, rangeRate: rr) / 10).rounded() * 10

        let key = "\(u.id)|\(mode?.rawValue ?? "")"
        if key != appliedModeKey {
            try await tuneLink.set("S 1 VFOB")
            try await tuneLink.set("M \(Self.hamlibMode(u.downlinkMode, tx: nil)) 0")
            try await tuneLink.set("X \(Self.hamlibMode(u.modeName, tx: mode)) 0")
            // Tone 0 clears any tone left over from another satellite.
            let tone = Int((u.ctcssHz ?? 0) * 10)
            if tone > 0 {
                try await tuneLink.set("C \(tone)")
            } else {
                try? await tuneLink.set("C 0")
            }
            appliedModeKey = key
        }
        try await tuneLink.set("F \(Int(rx))")
        try await tuneLink.set("I \(Int(tx))")

        // The list only protects anything if the radio really went there, so read it back.
        let read = Double(try await tuneLink.get("i")) ?? 0
        let confirmed = abs(read - tx) < 500
        txHz = read
        signalHz = Doppler.uplink(nominalTx, rangeRate: rr)
        rxHz = rx
        dopplerHz = tx - nominalDial
        if confirmed != uplinkConfirmed { uplinkConfirmed = confirmed }
    }

    private func confirmStillKeyed() {
        Task {
            do {
                let v = try await pttLink.get("t")
                if v != "1", isKeyed { release("Radio stopped transmitting") }
            } catch { radioLost(error) }
        }
    }

    private func radioLost(_ error: Error) {
        guard radio == .connected else { return }
        if isPressing { release("Radio link lost") }
        uplinkConfirmed = false
        radio = .failed(error.localizedDescription)
    }

    static func hamlibMode(_ name: String, tx: TxMode?) -> String {
        switch tx {
        case .fmVoice: return "FM"
        case .aprs, .aprsPosition, .packet1200, .packet9600: return "PKTFM"
        case .cw, .psk31, .rtty, .ft8, .ft4:
            return name.uppercased() == "USB" ? "PKTUSB" : "PKTLSB"
        case .ssbVoice: return name.uppercased() == "USB" ? "USB" : "LSB"
        case nil:
            let n = name.uppercased()
            if n == "USB" || n == "LSB" || n == "CW" { return n }
            return "FM"
        }
    }

    // MARK: Keying

    func press() {
        guard !isPressing else { return }
        alarm = nil
        tick()
        guard canTransmit, let u = uplink, let m = mode, let rr = rangeRate else {
            lastEvent = "Blocked: " + (currentChecks().firstFailure.map { "\($0.id). \($0.detail)" } ?? "not ready")
            return
        }
        // Rendered first: a message that can't be built must fail before the radio keys.
        var samples: [Float]?
        if !m.isVoice {
            samples = TxSignal.render(mode: m, message: outgoing, callsign: callsign, path: packetPath, usb: u.isUSB)
            guard samples != nil else {
                lastEvent = "Blocked: this message can't be sent in \(m.rawValue)"
                return
            }
        }
        isPressing = true
        pressToken &+= 1
        let token = pressToken
        Task {
            do {
                try await applyTuning(u, rangeRate: rr)
                guard isPressing, token == pressToken else { return }
                guard uplinkConfirmed else { throw RigError(message: "Radio didn't confirm the uplink frequency") }

                // FT8 and FT4 wait for the next UTC boundary, without keying until just before it.
                var slotStart: Double?
                if let slot = m.slotSeconds {
                    let now = Date().timeIntervalSince1970
                    let next = (now / slot).rounded(.up) * slot
                    slotStart = next
                    waitingForSlot = true
                    defer { waitingForSlot = false }
                    let delay = next - now - 0.25
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard isPressing, token == pressToken else { return }
                    if let r = rangeRate { try await applyTuning(u, rangeRate: r) }
                    guard isPressing, token == pressToken, uplinkConfirmed else { return }
                }

                try await pttLink.set("T 1")
                guard isPressing, token == pressToken else { await unkey(); return }
                let state = try await pttLink.get("t")
                guard state == "1" else { throw RigError(message: "Radio didn't confirm transmit") }
                isKeyed = true
                keyedAt = Date()
                lastEvent = nil
                logEntry = TxLog.Entry(start: Date(), callsign: callsign, satellite: app.locked?.name ?? "", norad: app.locked?.norad ?? 0,
                                       nominalHz: u.signalHz(position: passbandPosition, mode: m), txHz: txHz ?? 0, mode: m.rawValue,
                                       elevation: elevation ?? 0, radio: radioKind.rawValue)
                // Radios need a moment to switch over before audio is worth sending.
                let settle = slotStart.map { max(0.05, $0 - Date().timeIntervalSince1970) } ?? 0.15
                try? await Task.sleep(for: .seconds(settle))
                guard isPressing, token == pressToken else { return }
                try await startAudio(m, samples: samples)
            } catch {
                if token == pressToken { release("Could not transmit: \(error.localizedDescription)") }
            }
        }
    }

    /// Digipeater aliases: ISS answers to ARISS, most others to APRSAT.
    var packetPath: [String] { app.locked?.norad == 25544 ? ["ARISS"] : ["APRSAT"] }

    func release(_ reason: String = "Released") {
        guard isPressing || isKeyed else { return }
        isPressing = false
        isKeyed = false
        pressToken &+= 1
        audio.stop()
        keyedAt = nil
        lastEvent = reason
        if var e = logEntry {
            e.end = Date(); e.reason = reason
            TxLog.append(e)
            logEntry = nil
        }
        Task { await unkey() }
    }

    /// Keeps trying and checks the result: failing to unkey is the one failure that needs shouting about.
    private func unkey() async {
        for _ in 0..<3 {
            if (try? await pttLink.set("T 0")) != nil, (try? await pttLink.get("t")) == "0" { return }
            try? await pttLink.connect(port: activePort)
        }
        alarm = "The radio didn't confirm it stopped transmitting. Check it now."
    }

    private func startAudio(_ m: TxMode, samples: [Float]?) async throws {
        if m.isVoice {
            if let d = audioDevice { try await audio.startMic(device: d.id) }
            return
        }
        guard let d = audioDevice, let samples else { throw RigError(message: "No audio output") }
        try audio.play(samples, device: d.id, volume: outputVolume) { [weak self] in self?.release("Message sent") }
    }
}

/// A record of every transmission, for station logs.
enum TxLog {
    struct Entry {
        var start: Date
        var end: Date = Date()
        var callsign: String
        var satellite: String
        var norad: Int
        var nominalHz: Double
        var txHz: Double
        var mode: String
        var elevation: Double
        var radio: String
        var reason: String = ""
    }

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vessel", isDirectory: true).appendingPathComponent("transmit_log.csv")
    }

    static func append(_ e: Entry) {
        let f = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let fields: [String] = [
            f.string(from: e.start), f.string(from: e.end), String(format: "%.1f", e.end.timeIntervalSince(e.start)), q(e.callsign),
            q(e.satellite), String(e.norad), String(Int(e.nominalHz)), String(Int(e.txHz)), q(e.mode),
            String(format: "%.1f", e.elevation), q(e.radio), q(e.reason),
        ]
        let line = fields.joined(separator: ",") + "\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            let header = "start_utc,end_utc,seconds,callsign,satellite,norad,uplink_hz,tx_hz,mode,elevation_deg,radio,ended_because\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
    }
}
