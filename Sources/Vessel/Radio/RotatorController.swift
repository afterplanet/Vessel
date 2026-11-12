import Foundation

/// Where to point an antenna on a rotator with limits. Kept free of hardware so it can be checked.
struct RotatorPlan: Equatable {
    var azMin = 0.0
    var azMax = 360.0
    var elMax = 90.0
    var minElevation = 0.0
    /// Smaller changes aren't worth wearing the motors for.
    var deadband = 2.0

    enum Action: Equatable {
        case track(az: Double, el: Double)
        case waitAtRise(az: Double, el: Double)
        case hold
    }

    /// The same bearing can have two positions on a rotator that turns past 360°. Uses the closer one,
    /// so it doesn't swing all the way round for a satellite crossing north.
    func azimuth(_ target: Double, from current: Double) -> Double {
        let base = target.truncatingRemainder(dividingBy: 360)
        let normal = base < 0 ? base + 360 : base
        let options = [normal - 360, normal, normal + 360].filter { $0 >= azMin && $0 <= azMax }
        return options.min { abs($0 - current) < abs($1 - current) } ?? min(azMax, max(azMin, normal))
    }

    /// Leaves a wanted position alone unless it's far enough away to be worth moving for.
    func settle(_ wanted: Action, currentAz: Double, currentEl: Double) -> Action {
        switch wanted {
        case .track(let az, let el), .waitAtRise(let az, let el):
            return abs(az - currentAz) < deadband && abs(el - currentEl) < deadband ? .hold : wanted
        case .hold:
            return .hold
        }
    }

    func action(lookAz: Double?, lookEl: Double?, riseAz: Double?, currentAz: Double, currentEl: Double) -> Action {
        var wanted: Action = .hold
        if let lookAz, let lookEl, lookEl >= minElevation {
            wanted = .track(az: azimuth(lookAz, from: currentAz), el: min(elMax, max(0, lookEl)))
        } else if let riseAz {
            wanted = .waitAtRise(az: azimuth(riseAz, from: currentAz), el: min(elMax, max(0, minElevation)))
        }
        switch wanted {
        case .track(let az, let el), .waitAtRise(let az, let el):
            return abs(az - currentAz) < deadband && abs(el - currentEl) < deadband ? .hold : wanted
        case .hold:
            return .hold
        }
    }
}

/// Points an antenna at the locked satellite through Hamlib's rotctld, the same interface SatDump
/// uses. The antenna only moves when tracking is on, or when asked to park.
@MainActor
final class RotatorController: ObservableObject {
    enum Connection: String, CaseIterable, Identifiable {
        case network = "rotctld at an address"
        case usb = "USB rotator"
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    enum Activity: Equatable {
        case idle
        case tracking
        case waitingAtRise
        case waitingForSatellite
        case needsLocation
        case parked
    }

    private static let defaults = UserDefaults.standard

    @Published var showSettings = false
    @Published private(set) var status = Status.off
    @Published private(set) var activity = Activity.idle
    @Published private(set) var isTracking = false
    @Published private(set) var actualAz: Double?
    @Published private(set) var actualEl: Double?
    @Published private(set) var targetAz: Double?
    @Published private(set) var targetEl: Double?
    @Published private(set) var usbModels: [(id: Int, name: String)] = []
    @Published private(set) var usbPorts: [String] = []

    @Published var connection = Connection(rawValue: defaults.string(forKey: "rotator.connection") ?? "") ?? .network {
        didSet { Self.defaults.set(connection.rawValue, forKey: "rotator.connection"); if connection != oldValue { disconnect() } }
    }
    @Published var address = defaults.string(forKey: "rotator.address") ?? "127.0.0.1" {
        didSet { Self.defaults.set(address, forKey: "rotator.address") }
    }
    @Published var port = defaults.object(forKey: "rotator.port") as? Int ?? 4533 {
        didSet { Self.defaults.set(port, forKey: "rotator.port") }
    }
    @Published var usbModel = defaults.object(forKey: "rotator.usbModel") as? Int ?? 603 {
        didSet { Self.defaults.set(usbModel, forKey: "rotator.usbModel") }
    }
    @Published var usbPort = defaults.string(forKey: "rotator.usbPort") ?? "" {
        didSet { Self.defaults.set(usbPort, forKey: "rotator.usbPort") }
    }
    @Published var usbBaud = defaults.object(forKey: "rotator.usbBaud") as? Int ?? 9600 {
        didSet { Self.defaults.set(usbBaud, forKey: "rotator.usbBaud") }
    }
    @Published var updateSeconds = defaults.object(forKey: "rotator.update") as? Double ?? 2 {
        didSet { Self.defaults.set(updateSeconds, forKey: "rotator.update") }
    }
    @Published var turnsPast360 = defaults.bool(forKey: "rotator.450") {
        didSet { Self.defaults.set(turnsPast360, forKey: "rotator.450") }
    }
    @Published var tiltsPast90 = defaults.bool(forKey: "rotator.180") {
        didSet { Self.defaults.set(tiltsPast90, forKey: "rotator.180"); path = nil; riseValidUntil = .distantPast }
    }
    /// The plan for the pass in progress or coming up, when one could be made.
    @Published private(set) var path: RotatorPath?
    @Published var minElevation = defaults.object(forKey: "rotator.minEl") as? Double ?? 0 {
        didSet { Self.defaults.set(minElevation, forKey: "rotator.minEl") }
    }
    @Published var deadband = defaults.object(forKey: "rotator.deadband") as? Double ?? 2 {
        didSet { Self.defaults.set(deadband, forKey: "rotator.deadband") }
    }
    @Published var waitAtRise = defaults.object(forKey: "rotator.waitAtRise") as? Bool ?? true {
        didSet { Self.defaults.set(waitAtRise, forKey: "rotator.waitAtRise") }
    }
    @Published var parkAz = defaults.object(forKey: "rotator.parkAz") as? Double ?? 0 {
        didSet { Self.defaults.set(parkAz, forKey: "rotator.parkAz") }
    }
    @Published var parkEl = defaults.object(forKey: "rotator.parkEl") as? Double ?? 0 {
        didSet { Self.defaults.set(parkEl, forKey: "rotator.parkEl") }
    }

    var isConnected: Bool { status == .connected }

    /// What's connected, for the button in Listener.
    var displayName: String {
        switch connection {
        case .network: return "Rotator at \(address)"
        case .usb: return usbModels.first { $0.id == usbModel }?.name ?? "USB rotator"
        }
    }

    private unowned let app: AppState
    private let link = RigLink(label: "rotator")
    private var process: Process?
    private var loop: Task<Void, Never>?
    private var lookSat: Satellite?
    private var lookNorad: Int?
    private var riseAz: Double?
    private var riseValidUntil = Date.distantPast
    private var riseTask: Task<Void, Never>?

    init(app: AppState) { self.app = app }

    private var plan: RotatorPlan {
        RotatorPlan(azMin: 0, azMax: turnsPast360 ? 450 : 360, elMax: 90, minElevation: minElevation, deadband: deadband)
    }

    // MARK: Connecting

    func loadUSBChoices() {
        usbPorts = RadioFinder.ports()
        if usbPort.isEmpty || !usbPorts.contains(usbPort) { usbPort = usbPorts.first ?? "" }
        guard usbModels.isEmpty, let path = TransmitController.rigctld?.replacingOccurrences(of: "rigctld", with: "rotctl") else { return }
        Task {
            let list = await Task.detached(priority: .utility) { RadioFinder.hamlibList(rigctl: path) }.value
            usbModels = Self.parseModels(list)
        }
    }

    /// "   603  Yaesu   GS-232B   20220109.0  Stable  ROT_MODEL_GS232B", leaving out Hamlib's own stand-ins.
    nonisolated static func parseModels(_ list: String) -> [(id: Int, name: String)] {
        list.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "  ", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3, let id = Int(columns[0]), id > 2 else { return nil }
            return (id, "\(columns[1]) \(columns[2])")
        }
        .sorted { $0.name < $1.name }
    }

    func connect() {
        guard status != .connecting, !isConnected else { return }
        status = .connecting
        Task {
            do {
                let (host, tcp) = try startDaemon()
                var failure: Error?
                // Hamlib's own daemon needs a moment before it listens.
                for _ in 0..<20 {
                    do {
                        try await link.connect(host: host, port: tcp)
                        failure = nil
                        break
                    } catch {
                        failure = error
                        if connection == .network { break }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                if let failure { throw failure }
                try await poll()
                status = .connected
                startLoop()
            } catch {
                stopDaemon()
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func startDaemon() throws -> (String, Int) {
        if connection == .network { return (address, port) }
        guard let path = TransmitController.rigctld?.replacingOccurrences(of: "rigctld", with: "rotctld") else {
            throw RigError(message: "Hamlib isn't installed. Run: brew install hamlib")
        }
        let tcp = Int.random(in: 19000...19999)
        guard !usbPort.isEmpty else { throw RigError(message: "No USB device to use") }
        let arguments = ["-T", "127.0.0.1", "-t", String(tcp), "-m", String(usbModel), "-r", usbPort, "-s", String(usbBaud)]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        return ("127.0.0.1", tcp)
    }

    private func stopDaemon() {
        process?.terminate()
        process = nil
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        if isConnected, isTracking { link.setBlocking("S") }
        link.disconnect()
        stopDaemon()
        isTracking = false
        activity = .idle
        actualAz = nil
        actualEl = nil
        status = .off
    }

    /// For quitting: nothing should keep moving with nobody watching.
    func shutdown() { disconnect() }

    // MARK: Moving

    func setTracking(_ on: Bool) {
        guard isConnected, !on || app.supportsRotator else { return }
        isTracking = on
        if !on {
            activity = .idle
            Task { try? await link.set("S") }
        }
    }

    /// Stops the motors at once, and tracking with them.
    func stop() {
        isTracking = false
        activity = .idle
        guard isConnected else { return }
        Task { try? await link.set("S") }
    }

    func park() {
        guard isConnected else { return }
        isTracking = false
        activity = .parked
        let az = plan.azimuth(parkAz, from: actualAz ?? 0), el = parkEl
        Task { try? await link.set(String(format: "P %.1f %.1f", az, el)) }
    }

    private func poll() async throws {
        let reply = try await link.lines("p", count: 2)
        guard reply.count == 2, let az = Double(reply[0]), let el = Double(reply[1]) else {
            throw RigError(message: "The rotator didn't report its position")
        }
        actualAz = az
        actualEl = el
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.step()
                } catch {
                    // Never carry on driving a rotator whose position isn't known.
                    self.fail(error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .seconds(max(0.5, self.isTracking ? self.updateSeconds : 1)))
            }
        }
    }

    private func fail(_ message: String) {
        link.disconnect()
        stopDaemon()
        loop = nil
        isTracking = false
        activity = .idle
        status = .failed(message)
    }

    private func step() async throws {
        try await poll()
        updateTarget()
        // Picking a public source turns tracking off, but this is what moves a real antenna, so check here too.
        if isTracking, !app.supportsRotator { stop() }
        guard isTracking else { return }
        guard app.ownStation != nil else { activity = .needsLocation; return }
        guard app.locked != nil else { activity = .waitingForSatellite; return }
        var action = plan.action(lookAz: targetAz, lookEl: targetEl, riseAz: waitAtRise ? riseAz : nil,
                                 currentAz: actualAz ?? 0, currentEl: actualEl ?? 0)
        // A planned pass overrides the moment-by-moment choice, which can't see a long swing coming.
        if let path, let el = targetEl {
            let now = Date()
            if el >= minElevation, let p = path.position(at: now) {
                action = plan.settle(.track(az: p.az, el: p.el), currentAz: actualAz ?? 0, currentEl: actualEl ?? 0)
            } else if waitAtRise, now < path.aos, let first = path.points.first {
                action = plan.settle(.waitAtRise(az: first.az, el: max(first.el, min(plan.elMax, minElevation))), currentAz: actualAz ?? 0, currentEl: actualEl ?? 0)
            }
        }
        switch action {
        case .track(let az, let el):
            activity = .tracking
            try await link.set(String(format: "P %.1f %.1f", az, el))
        case .waitAtRise(let az, let el):
            activity = .waitingAtRise
            try await link.set(String(format: "P %.1f %.1f", az, el))
        case .hold:
            // Close enough for now. Says which of the two it's holding for.
            if let el = targetEl, el >= minElevation { activity = .tracking }
            else { activity = waitAtRise && riseAz != nil ? .waitingAtRise : .waitingForSatellite }
        }
    }

    /// From your own location, as this antenna is yours even when listening through a public host.
    private func updateTarget() {
        guard let st = app.ownStation, let sat = app.locked else {
            targetAz = nil; targetEl = nil; lookSat = nil; lookNorad = nil; riseAz = nil; path = nil
            return
        }
        if lookNorad != sat.norad {
            lookNorad = sat.norad
            lookSat = sat.clone()
            riseAz = nil
            path = nil
            riseValidUntil = .distantPast
        }
        let jd = Astro.julianDate()
        guard let s = lookSat?.state(jd: jd) else { return }
        let look = Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon)
        targetAz = look.az
        targetEl = look.el
        if Date() >= riseValidUntil { findRise(sat, from: st) }
    }

    /// The bearing where it next comes up, to be already pointing there.
    private func findRise(_ sat: Satellite, from st: Station) {
        riseValidUntil = Date().addingTimeInterval(120)
        guard let copy = sat.clone() else { return }
        let box = RiseBox(sat: copy)
        riseTask?.cancel()
        riseTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> (az: Double, until: Date)? in
                guard case .pass(let p) = AppState.predict(box.sat, st) else { return nil }
                let jd = p.aos.timeIntervalSince1970 / 86400 + 2440587.5
                guard let s = box.sat.state(jd: jd) else { return nil }
                return (Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon).az, p.los)
            }.value
            let limits = RotatorPath.Limits(azMin: 0, azMax: self?.turnsPast360 == true ? 450 : 360, elMax: self?.tiltsPast90 == true ? 180 : 90)
            let from = self.flatMap { c in c.actualAz.map { RotatorPath.Position(az: $0, el: c.actualEl ?? 0) } }
            let planned = await Task.detached(priority: .utility) { () -> RotatorPath? in
                guard let pass = PassPredictor.passes(box.sat, lat: st.lat, lon: st.lon, hours: 24).first else { return nil }
                return RotatorPath.plan(track: pass.track, aos: pass.aos, los: pass.los, limits: limits, from: from)
            }.value
            guard let self, !Task.isCancelled else { return }
            // Kept for the whole pass once it has started: changing course midway is what causes swings.
            if self.path.map({ Date() < $0.aos || Date() > $0.los }) ?? true { self.path = planned }
            self.riseAz = found?.az
            if let until = found?.until { self.riseValidUntil = until }
        }
    }
}

private struct RiseBox: @unchecked Sendable { let sat: Satellite }
