import Combine
import SwiftUI
import MapKit

struct Station: Equatable, Codable {
    var name: String
    var lat: Double
    var lon: Double
    var iso: String
    /// A spy host's position is somewhere else entirely, so it can never be a place to transmit from.
    var fromSpyHost: Bool = false
}

enum HostConnection: Equatable { case connecting, connected, failed }

/// Everything that decides what's being listened to. Any change means restarting SatDump.
struct ListenKey: Equatable {
    let norad: Int
    let frequency: Double
    let pipeline: String
    let source: String
    let address: String
    let port: Int
    let sampleRate: Double
    let output: ListenOutput
    let agc: Bool
    var ppm = 0.0
}

/// The sidebar shows one side of the station at a time.
enum PanelMode: String, CaseIterable, Identifiable {
    case receive = "Receive", transmit = "Transmit"
    var id: String { rawValue }
    var other: PanelMode { self == .receive ? .transmit : .receive }
    /// What the switch button calls this side.
    var buttonTitle: String { self == .receive ? "Receiver" : "Transmitter" }
    var symbol: String { self == .receive ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.up.forward" }
}

/// What listening does with the signal.
enum ListenOutput: String, CaseIterable, Identifiable {
    case decode = "Live decoding", file = "Save to file only"
    var id: String { rawValue }
    var captureMode: CaptureMode { self == .decode ? .listen : .record }
}

struct PassInfo: Equatable {
    var aos: Date
    var los: Date
    var maxElevation: Double
    var inProgress: Bool
}

enum PassWords {
    /// "AOS 6:56 PM · leaves 7:07 PM · max 42°", with the date when it isn't today.
    static func times(_ p: PassInfo) -> String {
        let aos = Calendar.current.isDateInToday(p.aos)
            ? p.aos.formatted(date: .omitted, time: .shortened) : p.aos.formatted(date: .abbreviated, time: .shortened)
        let leaves = p.los.formatted(date: .omitted, time: .shortened)
        return p.inProgress ? "Leaves \(leaves) · max \(Int(p.maxElevation))°" : "AOS \(aos) · leaves \(leaves) · max \(Int(p.maxElevation))°"
    }
}

enum PassState: Equatable {
    case unknown, computing
    case pass(PassInfo)
    case alwaysVisible
    case none
}

@MainActor
final class AppState: ObservableObject {
    @Published var locked: Satellite?
    @Published var followLocked = false
    /// nil shows every type.
    @Published var orbitFilter: OrbitClass?
    @Published var satelliteFilter = SatelliteFilter()
    @Published var showScan = false
    /// Frequencies chosen from a scan, by NORAD number, for satellites with none listed.
    @Published private(set) var scanFound: [String: Double] = UserDefaults.standard.dictionary(forKey: "scanFound") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(scanFound, forKey: "scanFound") }
    }
    /// Starts muted, so a pass arriving unattended can't suddenly blast noise.
    @Published var speakerOn = UserDefaults.standard.bool(forKey: "speakerOn") {
        didSet {
            UserDefaults.standard.set(speakerOn, forKey: "speakerOn")
            syncAudio()
        }
    }
    /// Never plays into a microphone that's going out on the air.
    var transmitKeyed = false {
        didSet { syncAudio() }
    }
    let audioMonitor = AudioMonitor()
    let sstv = SSTVMonitor()
    let packets = PacketMonitor()
    let ft = FTMonitor()
    let formats = FormatMonitor()

    /// A spacecraft shown in its own view, as the globe can't reach it.
    @Published private(set) var spaceObject: SpaceObject?

    /// Spacecraft are satellites like any other: this locks one, with all that brings.
    func openSpaceObject(_ object: SpaceObject, store: SatelliteStore?) {
        guard let sat = store?.satellite(norad: object.noradID) else { return }
        lock(sat)
        renderer?.lookAt(norad: sat.norad)
    }

    /// Back to the globe. It stays locked, so it can still be listened to.
    func closeSpaceObject() { spaceObject = nil }

    func showSpaceView() { spaceObject = locked?.spaceObject.flatMap { $0.horizons != nil ? $0 : nil } }

    /// Ways the menu bar reaches things held by the window.
    @Published var toggleSidebarRequest = 0
    @Published var showSidebarRequest = 0
    @Published var showFilters = Snapshot.arguments.contains("--filters-open")

    @Published private(set) var findingMyLocation = false
    @Published var gpsOffer: GPSOffer?
    @Published private(set) var savedLocations = SavedLocation.load()
    @Published private(set) var locationNote: LocationNote?
    private var noteToken = 0
    @Published var pickingLocation = false {
        didSet { if pickingLocation { pickingHostRegion = false } }
    }
    /// The next click on the globe lists the hosts around it, instead of setting the address.
    @Published var pickingHostRegion = false {
        didSet { if pickingHostRegion { pickingLocation = false } }
    }
    /// The clicked spot the host list is narrowed to.
    @Published private(set) var hostRegion: Station? {
        didSet { if hostRegion != nil { hostsForSatellite = false } }
    }
    /// The host list shows who can hear the locked satellite, and waits for one if none is locked.
    @Published var hostsForSatellite = false {
        didSet {
            guard hostsForSatellite != oldValue else { return }
            if hostsForSatellite { hostRegion = nil }
            computeHostArrivals()
        }
    }
    @Published private(set) var hostArrivals: [String: HostArrival] = [:]
    @Published private(set) var hostArrivalsReady = false
    private var hostArrivalTask: Task<Void, Never>?
    private var nextArrivalChange = Date.distantFuture
    @Published var findingAddress = false
    @Published var station: Station?
    @Published var hosts: [SpyHost] = []
    @Published var selectedHostID: String?
    @Published var hostsStatus = ""
    /// The receiver-station directories have answered, or failed to, at least once this launch.
    @Published private(set) var hostsLoaded = false
    /// nil while unknown or checking.
    @Published var hostReachable: Bool?
    @Published private(set) var hostHealth: [String: HostHealth] = [:]
    @Published var isPreparing = false
    /// The selected host only: every other host has no connection to show.
    @Published private(set) var connection: HostConnection?
    /// How good the path to each host is, for the circles in the list.
    @Published private(set) var hostLinks: [String: HostLink] = [:]
    var hostLink: HostLink? { selectedHostID.flatMap { hostLinks[$0] } }
    @Published var showSpectrum = false
    /// The last place typed or picked: hosts there stay at the top, even after choosing one elsewhere.
    @Published private(set) var hostSearchPlace: Station?
    @Published var globeReady = false
    @Published var globeProblem: String?
    /// Remembered per source, since it's a property of each radio's setup.
    @Published private var agcChoices = UserDefaults.standard.dictionary(forKey: "agcChoices") as? [String: Bool] ?? [:] {
        didSet { UserDefaults.standard.set(agcChoices, forKey: "agcChoices") }
    }
    @Published var panelMode = PanelMode(rawValue: UserDefaults.standard.string(forKey: "panelMode") ?? "") ?? .receive {
        didSet { UserDefaults.standard.set(panelMode.rawValue, forKey: "panelMode") }
    }
    @Published var listenOutput = ListenOutput(rawValue: UserDefaults.standard.string(forKey: "listenOutput") ?? "") ?? .decode {
        didSet { UserDefaults.standard.set(listenOutput.rawValue, forKey: "listenOutput") }
    }
    @Published var autoListen = UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoListen, forKey: "autoListen") }
    }
    /// Why it is or isn't listening right now, shown in the Capture panel.
    @Published private(set) var autoStatus = ""
    /// False until the slider is touched: a spy server then sets gain itself, and USB radios start mid-range.
    @Published var gainIsManual = false
    @Published var captureError: String?
    @Published var sourceID = "spyserver" {
        didSet {
            if source.kind != .spy {
                connection = nil
                pickingHostRegion = false
                hostRegion = nil
                hostsForSatellite = false
            }
            computeHostArrivals()
            // A sensible start for this radio: strong enough to hear, short of overloading it.
            if !gainIsManual {
                let r = source.gainRange
                gain = (r.lowerBound + (r.upperBound - r.lowerBound) * 0.7).rounded()
            }
            guard selectedHost?.network != hostNetwork || source.kind != .spy else { return }
            selectedHostID = nil
            if station?.fromSpyHost == true {
                // Back to your own place: a host's position was only ever borrowed.
                station = UserDefaults.standard.data(forKey: "typedStation").flatMap { try? JSONDecoder().decode(Station.self, from: $0) }
                stationChanged()
            }
        }
    }
    @Published var address = ""
    @Published var port = 5555
    @Published var tune = TuneSelection(pipeline: nil, frequencyHz: nil, sampleRate: 1_000_000, reason: "")
    @Published var pipelineOverrideID: String?
    @Published var frequencyOverride: Double?
    @Published var gain: Double = 10
    @Published var bias = false
    @Published var bitDepth = 16
    @Published var basebandFormat = "cs16"
    /// Picks the lowest rate and depth that hold the signal on public hosts, which often can't send more.
    @Published var matchHostRate = UserDefaults.standard.object(forKey: "matchHostRate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(matchHostRate, forKey: "matchHostRate") }
    }
    /// Hosts that recently couldn't deliver: what they managed, and when that was measured.
    @Published private(set) var slowHosts: [String: (rate: Double, at: Date)] = [:]
    @Published private(set) var testingSpeed = false
    @Published var dcBlock = false
    @Published var iqSwap = false
    /// On by default: this is the step that turns decoded frames into images.
    @Published var finishProcessing = true
    @Published var stopAtLOS = false
    /// Stop a capture once its files reach this size. Nil means no limit.
    @Published var sizeLimitMB: Int? = {
        let v = UserDefaults.standard.integer(forKey: "sizeLimitMB")
        return v > 0 ? v : nil
    }() {
        didSet {
            if let v = sizeLimitMB, v <= 0 { sizeLimitMB = nil; return }
            UserDefaults.standard.set(sizeLimitMB ?? 0, forKey: "sizeLimitMB")
        }
    }
    /// Plain information about how a capture ended, which isn't a failure.
    @Published var captureNote: String?
    @Published var stopOnNoise = UserDefaults.standard.bool(forKey: "stopOnNoise") {
        didSet { UserDefaults.standard.set(stopOnNoise, forKey: "stopOnNoise") }
    }
    @Published var outputDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vessel", isDirectory: true)

    @Published var azimuth: Double?
    @Published var elevation: Double?
    @Published var rangeKm: Double?
    @Published var pass: PassState = .unknown

    weak var renderer: GlobeRenderer?
    let runner: SatDumpRunner

    /// What's plugged in right now, which is all the Hardware section of Source lists.
    @Published private(set) var attachedHardware: [AttachedHardware] = []
    private let usbWatcher = USBWatcher()
    private let rtlProbe = RTLTunerProbe()
    /// The chip inside the plugged-in RTL-SDR, which decides what it can tune.
    @Published private(set) var rtlTuner: RTLTuner?
    private var usbHardware: [AttachedHardware] = []
    private var probedHardware: [DetectedDevice] = []
    private var probeAgain = false
    private var hardwareSeen = false
    private var probeWatch: AnyCancellable?
    private var lookTimer: Timer?
    private var probeTask: Task<Void, Never>?
    private var hostTimer: Timer?
    private var passTask: Task<Void, Never>?
    private var lookSat: Satellite?
    private var losStopTimer: Timer?
    private var pickToken = 0
    let choices = PipelineChoices()
    private var connectToken = 0
    private var linkTick = 0
    private var listeningKey: ListenKey?
    private var stoppedByUser: ListenKey?
    private var failedKey: ListenKey?
    private var retryAt = Date.distantPast
    private var stopIssued = false

    init(runner: SatDumpRunner) {
        self.runner = runner
        startWatchingHardware()
        if let d = UserDefaults.standard.data(forKey: "typedStation"),
           let s = try? JSONDecoder().decode(Station.self, from: d) { station = s }
        hostTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshHosts() }
        }
        lookTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLook()
                self?.autoListenTick()
                self?.linkTimerTick()
                self?.syncAudio()
            }
        }
    }

    var source: SDRSource { SDRCatalog.source(sourceID) ?? SDRCatalog.sources[0] }
    var selectedHost: SpyHost? { hosts.first { $0.id == selectedHostID } }
    var hostNetwork: SpyHost.Network { source.browserOnly ? .webSDR : .spyServer }
    var pipeline: Pipeline? {
        if let id = pipelineOverrideID { return runner.catalog.pipeline(id) }
        // A picture downlink isn't what the automatic decoder was chosen for.
        if let media = activeMedia, frequency != tune.frequencyHz {
            return media.kind == .sstv ? runner.catalog.pipeline("analog_demod") : nil
        }
        return tune.pipeline
    }

    var usingDemodulatorForLackOfDecoder: Bool {
        tune.noDecoder && pipelineOverrideID == nil && pipeline?.id == "analog_demod" && listenOutput == .decode
    }

    /// The picture or video signal currently tuned, if that's what this frequency carries.
    var activeMedia: MediaSignal? {
        guard let f = frequency else { return nil }
        return locked?.media.first { $0.hz == f }
    }

    /// Tunes to it and sets up what can actually be done with it.
    func tuneMedia(_ signal: MediaSignal) {
        frequencyOverride = signal.hz
        listenOutput = signal.kind == .sstv ? .decode : .file
    }
    var frequency: Double? { frequencyOverride ?? tune.frequencyHz }

    /// The rate actually requested: the pipeline's, capped by the device and snapped to what a spy host offers.
    var sampleRate: Double {
        if source.kind == .spy, let h = selectedHost { return rate(on: h) }
        return min(pipeline?.preferredRate ?? activeMedia?.neededSampleRate ?? tune.sampleRate, source.maxSampleRate)
    }

    private var matchesHost: Bool { source.kind == .spy && !source.browserOnly && matchHostRate }
    var effectiveBitDepth: Int { matchesHost ? 8 : bitDepth }
    var effectiveFormat: String { matchesHost ? "cs8" : basebandFormat }

    /// What the signal needs, on the downlink actually being used.
    private var neededRate: Double {
        let f = frequency ?? 0
        let tx = locked?.transmitters.first { $0.downlinkHz == f } ?? locked?.primaryDownlink
        return max(SignalRate.needed(symbolRate: pipeline?.symbolRate, baud: tx?.baud, frequency: f), activeMedia?.neededSampleRate ?? 0)
    }

    func rate(on h: SpyHost) -> Double {
        h.snappedRate(for: matchesHost ? neededRate : pipeline?.preferredRate ?? activeMedia?.neededSampleRate ?? tune.sampleRate)
    }

    private static let slowMemory: TimeInterval = 600

    /// Whether a host recently fell short of what this signal needs. Connections change, so this wears off.
    func isTooSlow(_ h: SpyHost) -> Bool {
        guard let s = slowHosts[h.id], Date().timeIntervalSince(s.at) < Self.slowMemory else { return false }
        return s.rate < rate(on: h) * Double(effectiveBitDepth) / 4 * Self.enoughDelivered
    }

    /// Said when even the host's top rate is too low to hold this signal.
    var rateShortfall: String? {
        guard matchesHost, let h = selectedHost, rate(on: h) < neededRate else { return nil }
        func r(_ v: Double) -> String { formatHz(v).replacingOccurrences(of: "Hz", with: "S/s") }
        return "This signal needs \(r(neededRate)), and this host tops out at \(r(rate(on: h)))."
    }

    /// A host delivering this share of what was asked for is keeping up.
    static let enoughDelivered = 0.85

    /// A running recording found the host falling behind, so remember that for next time.
    func noteDelivered(bytesPerSecond: Double) {
        if let h = selectedHost { slowHosts[h.id] = (bytesPerSecond, Date()) }
    }

    func lock(_ sat: Satellite) {
        // Those out of the globe's reach open their own view of where they are.
        spaceObject = sat.spaceObject.flatMap { $0.horizons != nil ? $0 : nil }
        locked = sat
        lookSat = sat.clone()
        retune()
        renderer?.lookAt(norad: sat.norad)
        renderer?.targetDistance = max(renderer?.targetDistance ?? 4, 1.6)
        updateLook()
        computePass()
        computeHostArrivals()
        lockHistory.record(sat)
    }

    let lockHistory = LockHistory()

    /// The same satellite with fresher orbit data. Leaves what's tuned alone, as a capture may be running.
    func refreshLocked(_ fresh: Satellite) {
        locked = fresh
        lookSat = fresh.clone()
        updateLook()
        computePass()
        computeHostArrivals()
    }

    func unlock() {
        spaceObject = nil
        locked = nil
        lookSat = nil
        followLocked = false
        azimuth = nil; elevation = nil; rangeKm = nil
        pass = .unknown
        passTask?.cancel()
        computeHostArrivals()
    }

    /// Frequency and pipeline always come from the locked satellite.
    /// Why the listener's current source can't scan, if it can't.
    var scanSourceProblem: String? {
        if runner.executable == nil, source.kind != .spy { return "The receiving engine is missing from this copy of Vessel." }
        if source.browserOnly { return "Web SDRs only open in a browser, so they can't be scanned. Choose another source in the Listener panel." }
        switch source.kind {
        case .spy:
            guard let h = selectedHost else { return "Pick a host in the Listener panel to scan through." }
            if !h.fullControl { return "This host's owner doesn't allow retuning, so it can't scan. Pick another." }
        case .network:
            if address.isEmpty { return "Enter this source's address in the Listener panel." }
        case .usb:
            if attachedDevice(for: source) == nil {
                return "Connect your \(source.name), or choose another source in the Listener panel."
            }
        }
        return nil
    }

    /// The scan always listens through whatever the Listener panel has selected.
    func scanSource(forceEngine: Bool = false) -> ScanSource? {
        guard scanSourceProblem == nil else { return nil }
        if source.kind == .spy, !forceEngine, let h = selectedHost { return .spy(h) }
        guard let exe = runner.executable else { return nil }
        let rates: [Double]
        if source.kind == .spy, let h = selectedHost {
            var r = h.maxSampleRate
            while r / 2 >= 1_000_000 { r /= 2 }
            rates = [r]
        } else {
            rates = source.scanRates
        }
        return .engine(.init(executable: exe, source: source, address: address, port: port, gain: sendsGain ? gain : nil, bias: bias,
                             extraArgs: agcActive ? agcSpec?.args ?? [] : [], rates: rates))
    }

    func scanFrequency(for sat: Satellite) -> Double? { scanFound[String(sat.norad)] }

    func useScannedFrequency(_ hz: Double, for sat: Satellite) {
        scanFound[String(sat.norad)] = hz
        retune()
    }

    func forgetScannedFrequency(for sat: Satellite) {
        scanFound[String(sat.norad)] = nil
        retune()
    }

    func retune() {
        frequencyOverride = nil
        guard let sat = locked else { pipelineOverrideID = nil; return }
        tune = runner.catalog.select(for: sat)
        // A listed frequency always wins over one found by scanning.
        if tune.frequencyHz == nil { frequencyOverride = scanFrequency(for: sat) }
        moveToReachableDownlink()
        // A decoder picked by hand for this satellite stays picked, as long as it still exists.
        if let saved = choices.manual(norad: sat.norad), runner.catalog.pipeline(saved) != nil {
            pipelineOverrideID = saved
            if let f = runner.catalog.pipeline(saved)?.frequenciesHz.first { frequencyOverride = f }
        } else {
            pipelineOverrideID = nil
            choices.recordAuto(norad: sat.norad, satellite: sat.name, pipeline: tune.pipeline?.id, reason: tune.reason)
        }
    }

    // MARK: Location

    /// Picking a host moves your location there, on the panels and the globe: that's where you're listening from.
    /// What the row for this host should show.
    func connectionDisplay(for h: SpyHost) -> HostConnection? {
        guard h.id == selectedHostID, let connection else { return nil }
        if connection == .failed { return .failed }
        if connection == .connecting || isPreparing || (runner.isRunning && !runner.isStreaming) { return .connecting }
        return .connected
    }

    /// The host to pin in place of the list: chosen, and its connection made.
    var pinnedHost: SpyHost? {
        guard source.kind == .spy, connection == .connected else { return nil }
        return selectedHost
    }

    /// Back to the list. Not while a capture is using the connection, as a stray double-click could end it.
    func disconnectHost() {
        guard !runner.isRunning, selectedHostID != nil else { return }
        connectToken &+= 1
        selectedHostID = nil
        connection = nil
        hostReachable = nil
        address = ""
        if station?.fromSpyHost == true {
            // A host's position was only ever borrowed.
            station = hostSearchPlace ?? UserDefaults.standard.data(forKey: "typedStation").flatMap { try? JSONDecoder().decode(Station.self, from: $0) }
            stationChanged()
        }
    }

    func selectHost(_ host: SpyHost) {
        captureError = nil
        failedKey = nil
        selectedHostID = host.id
        address = host.host
        port = host.port
        station = Station(name: host.placeName, lat: host.lat, lon: host.lon, iso: host.iso, fromSpyHost: true)
        stationChanged()
        connect(to: host)
        flyToStation()
        if host.city.isEmpty { nameStation(for: host) }
    }

    /// SpyServer's directory only has coordinates, so ask for the nearest town.
    private func nameStation(for host: SpyHost) {
        let id = host.id
        Task {
            let found = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: host.lat, longitude: host.lon))
            guard selectedHostID == id, let place = found?.first, station?.fromSpyHost == true else { return }
            let town = place.locality ?? place.subAdministrativeArea ?? place.administrativeArea
            if let town { station?.name = "\(town), \(host.countryName)" }
        }
    }

    private func linkTimerTick() {
        linkTick += 1
        if linkTick % 10 == 0, connection != nil { measureLink() }
        if Date() >= nextArrivalChange { computeHostArrivals() }
    }

    private func measureLink() {
        guard let h = selectedHost else { return }
        let id = h.id
        Task {
            let link = await HostProbe.measureLink(host: h.host, port: h.port)
            hostLinks[id] = link
        }
    }

    /// One line for the selected host's details.
    func connectionDetail(for h: SpyHost) -> String {
        switch connectionDisplay(for: h) {
        case .connecting: return runner.isRunning ? "Starting the stream…" : "Connecting…"
        case .failed: return h.isFull ? "Full, no free slot" : "Not answering"
        case .connected:
            if runner.isStreaming, let f = runner.spectrum.frequencyHz {
                return "\(runner.mode == .record ? "Recording" : "Listening") on \(formatHz(f)) at \(formatHz(runner.spectrum.sampleRate).replacingOccurrences(of: "Hz", with: "S/s"))"
            }
            return h.network == .webSDR ? "Reachable, opens in a browser" : "Connected, ready to listen"
        case nil: return ""
        }
    }

    /// Runs the host's real handshake. If a satellite is in view, the next tick starts listening
    /// through it, and the row keeps its spinner until SatDump is really streaming.
    private func connect(to host: SpyHost) {
        connection = .connecting
        hostReachable = nil
        connectToken &+= 1
        let token = connectToken
        Task {
            var result = await HostProbe.checkNow(host)
            // One retry: a busy host can miss a handshake while being perfectly usable.
            if result != .answering, token == connectToken { result = await HostProbe.checkNow(host) }
            guard token == connectToken else { return }
            hostHealth[host.id] = result
            hostReachable = result == .answering
            measureLink()
            if result == .answering, !host.isFull {
                connection = .connected
            } else {
                connection = .failed
                captureError = host.isFull ? "This host is full. Pick another." : "This host isn't answering. Pick another."
            }
            autoListenTick()
        }
    }

    /// nil goes back to automatic. Either way it's saved for this satellite.
    func choosePipeline(_ id: String?) {
        guard let sat = locked else { return }
        choices.setManual(norad: sat.norad, satellite: sat.name, pipeline: id)
        retune()
    }

    func syncAudio() {
        let live = runner.isRunning && runner.mode == .listen
        audioMonitor.follow(speakerOn && !transmitKeyed && live ? runner.outputDir : nil)
        sstv.follow(live ? runner.outputDir : nil)
        packets.follow(live ? runner.outputDir : nil)
        formats.follow(live ? runner.outputDir : nil)
        // SSB signals are demodulated here from the raw signal, which only Save to file keeps.
        let saving = runner.isRunning && runner.mode == .record && tunedTransponder != nil && ["cs16", "cs8"].contains(effectiveFormat)
        ft.follow(saving ? runner.outputDir : nil, centreHz: runner.spectrum.frequencyHz ?? 0, sampleRate: runner.spectrum.sampleRate,
                  usb: tunedTransponder?.mode.uppercased() != "LSB", satellite: locked, station: station)
    }

    /// The linear transponder the receiver is tuned inside, if it is.
    var tunedTransponder: Transmitter? {
        guard let sat = locked, let f = frequency else { return nil }
        return sat.transmitters.first { t in
            guard t.active, let high = t.downlinkHighHz, high > t.downlinkHz else { return false }
            return f >= t.downlinkHz - 5000 && f <= high + 5000
        }
    }

    /// What the current downlink is, according to its listing.
    var listedFormat: SignalFormat? {
        guard let f = frequency, let sat = locked else { return nil }
        let tx = sat.transmitters.first { $0.downlinkHz == f && $0.active } ?? sat.transmitters.first { $0.downlinkHz == f }
        return tx.flatMap(SignalFormat.listed)
    }

    /// What the receiver chosen in Listener can tune. A public network means the host in use,
    /// or with none chosen yet, everything its hosts cover between them.
    var receiverRanges: [ClosedRange<Double>]? {
        guard source.kind == .spy else {
            if source.id == "rtlsdr", let rtlTuner { return rtlTuner.ranges }
            return SDRCatalog.tunableRanges(source.id)
        }
        if let h = selectedHost { return [h.minHz...max(h.minHz, h.maxHz)] }
        let net = hostNetwork
        let all = hosts.filter { $0.network == net && !$0.listedOffline }.map { $0.minHz...max($0.minHz, $0.maxHz) }
        return all.isEmpty ? nil : SDRCatalog.merged(all)
    }

    /// For the Filters menu.
    var receiverRangeText: String {
        guard let ranges = receiverRanges else { return "\(source.name)'s range isn't known here, so this hides nothing." }
        let name: String
        if source.kind == .spy {
            name = selectedHost?.shortName ?? "Any \(source.browserOnly ? "Web SDR" : "SpyServer host")"
        } else {
            name = source.name
        }
        return "\(name): \(SDRCatalog.describe(ranges))"
    }

    /// Set when the tuned frequency is beyond your own receiver. A public host says this its own way.
    var rangeProblem: String? {
        guard source.kind != .spy, let f = frequency, let ranges = receiverRanges, !ranges.contains(where: { $0.contains(f) }) else { return nil }
        return "\(formatHz(f)) is outside \(source.name)'s range, \(SDRCatalog.describe(ranges))."
    }

    /// Moves off a frequency this receiver can't reach, if the satellite has one it can. One picked by hand stays.
    func moveToReachableDownlink() {
        guard source.kind != .spy, pipelineOverrideID == nil, rangeProblem != nil, let sat = locked, let ranges = receiverRanges else { return }
        if let f = SDRCatalog.reachableDownlink(of: sat.transmitters, in: ranges) { frequencyOverride = f }
    }

    /// Whether this downlink is meant to carry packets, so the panel says it's listening for them.
    var expectsPackets: Bool {
        guard let f = frequency, let tx = locked?.transmitters.first(where: { $0.downlinkHz == f }) else { return false }
        let text = "\(tx.mode) \(tx.description)".uppercased()
        return text.contains("AFSK") || text.contains("APRS") || PipelineCatalog.isAX25Data(tx)
    }

    /// A rotator turns your own antenna, which plays no part when a public host is doing the receiving.
    var supportsRotator: Bool { source.kind != .spy }

    /// Why there's nothing to hear, if there isn't.
    var speakerProblem: String? {
        if listenOutput != .decode { return "Save to file only has no sound. Choose Live decoding to hear it." }
        guard let pipeline else { return nil }
        return pipeline.hasAudio ? nil : "\(pipeline.name) is digital, so there's no sound to play"
    }

    /// The main button: starts whichever kind of listening is selected.
    func startListening() { startCapture(listenOutput.captureMode) }

    private func checkHost() {
        hostReachable = nil
        guard let h = selectedHost else { return }
        let id = h.id
        Task {
            let result = await HostProbe.check(h)
            hostHealth[id] = result
            if selectedHostID == id { hostReachable = result == .answering }
        }
    }

    /// On a public network the location follows the host, so a search finds the nearest one and
    /// moves there. On anything else, the search result is the user's own location.
    func setTypedLocation(name: String, coordinate: CLLocationCoordinate2D, iso: String) {
        let place = Station(name: name, lat: coordinate.latitude, lon: coordinate.longitude,
                            iso: iso.isEmpty ? Countries.shared.iso(lat: coordinate.latitude, lon: coordinate.longitude) : iso)
        hostSearchPlace = place
        // On a public network the list shows what's around the place, nearest first.
        hostRegion = source.kind == .spy ? place : nil
        // Listing them is the point, and connecting by itself would hide the list straight away.
        if source.kind == .spy, !runner.isRunning { disconnectHost() }
        station = place
        // A public network with nothing working shouldn't overwrite the user's own place.
        if source.kind != .spy, let d = try? JSONEncoder().encode(place) { UserDefaults.standard.set(d, forKey: "typedStation") }
        stationChanged()
    }

    /// Where you actually are, which a public host's borrowed position isn't.
    var ownStation: Station? {
        if let station, !station.fromSpyHost { return station }
        return UserDefaults.standard.data(forKey: "typedStation").flatMap { try? JSONDecoder().decode(Station.self, from: $0) }
    }

    /// The same test as the Start button.
    var canStartListening: Bool {
        canCapture && !(listenOutput == .decode && pipeline == nil) && !isPreparing
    }

    /// True while the address bar is following the selected public host.
    var locationLinkedToHost: Bool { source.kind == .spy }

    func flyToStation() {
        if let s = station { renderer?.fly(lat: Float(s.lat), lon: Float(s.lon)) }
    }

    /// The crosshair: nearby Wi-Fi first as it's far more exact, then the internet address if that can't answer.
    /// With no Wi-Fi at all, or nothing answering, it offers to use the GPS satellites instead.
    func findMyLocation(skipWifi: Bool = false) {
        guard !findingMyLocation else { return }
        findingMyLocation = true
        pickingLocation = false
        pickingHostRegion = false
        locationNote = nil
        pickToken &+= 1
        let token = pickToken
        Task {
            defer { findingMyLocation = false }
            let network = await NetworkStatus.check()
            guard token == pickToken else { return }
            if !network.wifi, !skipWifi {
                gpsOffer = GPSOffer(reason: network.internet ? "Not connected to Wi-Fi" : "No Wi-Fi or internet", canUseInternet: network.internet)
                return
            }
            let wifi: WifiLocator.Outcome = skipWifi ? .failed : await WifiLocator().locate()
            guard token == pickToken else { return }
            if case .found(let lat, let lon, let accuracy) = wifi {
                await use(FoundLocation(latitude: lat, longitude: lon, method: .wifi, accuracy: accuracy), wifi: wifi, token: token)
            } else if let found = await IPLocation.look() {
                guard token == pickToken else { return }
                await use(found, wifi: wifi, token: token)
            } else if token == pickToken {
                gpsOffer = GPSOffer(reason: "Couldn't find your location online", canUseInternet: false)
            }
        }
    }

    /// Chosen from the popup, when there's a connection but no Wi-Fi.
    func findFromInternetAddress() {
        guard !findingMyLocation else { return }
        findingMyLocation = true
        pickToken &+= 1
        let token = pickToken
        Task {
            defer { findingMyLocation = false }
            guard let found = await IPLocation.look() else {
                if token == pickToken { showLocationNote(.notFound) }
                return
            }
            guard token == pickToken else { return }
            await use(found, wifi: .failed, token: token)
        }
    }

    private func use(_ found: FoundLocation, wifi: WifiLocator.Outcome, token: Int) async {
        let coordinate = CLLocationCoordinate2D(latitude: found.latitude, longitude: found.longitude)
        var name = found.name
        var iso = found.iso
        if name == nil {
            let place = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: found.latitude, longitude: found.longitude)).first
            guard token == pickToken else { return }
            var seen = Set<String>()
            let parts = [place?.locality, place?.administrativeArea, place?.country].compactMap { $0 }.filter { seen.insert($0).inserted }
            name = parts.isEmpty ? nil : parts.joined(separator: ", ")
            iso = place?.isoCountryCode?.lowercased()
        }
        setTypedLocation(name: name ?? String(format: "%.3f°, %.3f°", found.latitude, found.longitude), coordinate: coordinate,
                         iso: iso ?? Countries.shared.iso(lat: found.latitude, lon: found.longitude))
        flyToStation()
        showLocationNote(found.method == .wifi ? .wifi(accuracy: found.accuracy) : .internetAddress(wifi: wifi))
    }

    /// A GPS position becomes the location, and stays in the address search until it's removed.
    func useGPSFix(_ fix: GPSFixPlan.Fix) {
        let name = "GPS " + SavedLocation.coordinates(latitude: fix.latitude, longitude: fix.longitude)
        let iso = Countries.shared.iso(lat: fix.latitude, lon: fix.longitude)
        savedLocations.insert(SavedLocation(name: name, latitude: fix.latitude, longitude: fix.longitude, iso: iso, saved: Date(),
                                            height: fix.height, spread: fix.spread), at: 0)
        SavedLocation.store(savedLocations)
        useSaved(savedLocations[0])
        gpsOffer = nil
        showLocationNote(.gps(spread: fix.spread))
    }

    func useSaved(_ place: SavedLocation) {
        pickToken &+= 1
        setTypedLocation(name: place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), iso: place.iso)
        flyToStation()
    }

    /// For checking the list's look without saving anything.
    func showPinnedForTest(_ places: [SavedLocation]) { savedLocations = places }

    func removeSaved(_ place: SavedLocation) {
        savedLocations.removeAll { $0.id == place.id }
        SavedLocation.store(savedLocations)
    }

    private func startWatchingHardware() {
        probeWatch = runner.$detectedDevices.dropFirst().sink { [weak self] devices in
            guard let self else { return }
            // Published while probing is still set, so the follow-up waits a moment for it to clear.
            if self.probeAgain {
                self.probeAgain = false
                self.probedHardware = []
                Task { @MainActor [weak self] in self?.askEngineForHardware() }
            } else {
                self.probedHardware = devices
            }
            self.updateHardware()
        }
        usbWatcher.onChange = { [weak self] found in
            guard let self else { return }
            self.usbHardware = found
            // What the engine said before may be about something that's now gone.
            self.probedHardware = []
            self.updateHardware()
            self.askEngineForHardware()
        }
        usbWatcher.start()
        usbHardware = USBWatcher.scan()
        updateHardware()
        askEngineForHardware()
    }

    /// Slower than USB, but it names things and finds whatever has no known USB numbers.
    private func askEngineForHardware() {
        guard !runner.isRunning else { return }
        if runner.probing { probeAgain = true } else { runner.probeDevices() }
    }

    private func updateHardware() {
        let old = attachedHardware
        let new = AttachedHardware.merge(usb: usbHardware, probed: probedHardware)
        attachedHardware = new
        identifyRTLTuner(old: old, new: new)
        let first = !hardwareSeen
        hardwareSeen = true
        guard !runner.isRunning, let next = AttachedHardware.sourceToUse(current: sourceID, old: old, new: new, firstLook: first), next != sourceID else { return }
        sourceID = next
    }

    /// Once each time a dongle arrives. The chip stays known until it's unplugged.
    private func identifyRTLTuner(old: [AttachedHardware], new: [AttachedHardware]) {
        let had = old.contains { $0.sourceID == "rtlsdr" }, has = new.contains { $0.sourceID == "rtlsdr" }
        if !has {
            if rtlTuner != nil { rtlTuner = nil }
            return
        }
        guard !had, rtlTuner == nil, !runner.isRunning, let engine = runner.executable else { return }
        rtlProbe.identify(engine: engine, folder: PipelineUpdater.runDir) { [weak self] tuner in
            guard let self, self.attachedHardware.contains(where: { $0.sourceID == "rtlsdr" }) else { return }
            self.rtlTuner = tuner
            self.moveToReachableDownlink()
        }
    }

    func attachedDevice(for source: SDRSource) -> AttachedHardware? {
        attachedHardware.first { $0.sourceID == source.id }
    }

    /// What's connected in Listener, set up for GPS. The gain is GPS's own, as a satellite's setting won't suit it.
    var gpsReceiver: GPSFixPlan.Receiver {
        GPSFixPlan.Receiver(source: source, address: address, port: port,
                            sampleRate: GPSFixPlan.sampleRate(for: source, listenerRate: sampleRate),
                            gain: agcReplacesGain ? nil : GPSFixPlan.gain(for: source), bias: bias, bitDepth: bitDepth,
                            sourceArgs: agcActive ? agcSpec?.args ?? [] : [])
    }

    /// The device found for the chosen source, for saying what's connected.
    var connectedDevice: String? { attachedDevice(for: source)?.name }

    var gpsReadiness: GPSFixPlan.Readiness {
        GPSFixPlan.readiness(source: source, address: address, connectedDevice: connectedDevice, listenerRate: sampleRate)
    }

    func closeLocationNote() {
        locationNote = nil
        // So the timer from this note can't close a later one.
        noteToken &+= 1
    }

    /// From the note under the address bar, when the location is only approximate.
    func scanGPSSatellites() {
        closeLocationNote()
        gpsOffer = GPSOffer(reason: "Your location is only approximate", canUseInternet: false)
    }

    func showLocationNote(_ note: LocationNote) {
        locationNote = note
        noteToken &+= 1
        let token = noteToken
        Task {
            // The ones that ask for something need longer to read.
            try? await Task.sleep(for: .seconds(note.offersGPSScan ? 30 : note.isWarning ? 14 : 6))
            if token == noteToken { locationNote = nil }
        }
    }

    /// A click on the globe: the marker moves at once, and the address follows when the lookup returns.
    func pickLocation(lat: Double, lon: Double) {
        if pickingHostRegion {
            pickingHostRegion = false
            setHostRegion(lat: lat, lon: lon)
            return
        }
        pickingLocation = false
        findingAddress = true
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let fallbackISO = Countries.shared.iso(lat: lat, lon: lon)
        let fallback = String(format: "%.3f°, %.3f°", lat, lon)
        station = Station(name: fallback, lat: lat, lon: lon, iso: fallbackISO)
        pickToken &+= 1
        let token = pickToken
        Task {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first
            guard token == pickToken else { return }
            findingAddress = false
            let parts = [placemark?.locality, placemark?.administrativeArea, placemark?.country].compactMap { $0 }
            var seen = Set<String>()
            let unique = parts.filter { seen.insert($0).inserted }
            let name = unique.isEmpty ? (placemark?.ocean ?? placemark?.inlandWater ?? fallback) : unique.joined(separator: ", ")
            setTypedLocation(name: name, coordinate: coordinate, iso: (placemark?.isoCountryCode ?? fallbackISO).lowercased())
        }
    }

    /// Named offline, like the hosts themselves. This only narrows the list: nothing connects
    /// and the address stays where it is until a host is chosen.
    private func setHostRegion(lat: Double, lon: Double) {
        let iso = Countries.shared.iso(lat: lat, lon: lon)
        let near = Places.shared.nearest(lat: lat, lon: lon)
        let name = OwnerCodes.countryName(iso: iso).map { SpyHost.shortName(country: $0, state: near?.state ?? "", city: near?.name ?? "") }
        hostRegion = Station(name: name ?? String(format: "%.1f°, %.1f°", lat, lon), lat: lat, lon: lon, iso: iso)
    }

    func clearHostRegion() { hostRegion = nil }

    func stationChanged() {
        updateLook()
        computePass()
    }

    func refreshHosts() async {
        defer { hostsLoaded = true }
        if hosts.isEmpty { hostsStatus = "Loading hosts…" }
        // Each directory stands alone: one being down must not empty the other's list.
        async let spy = try? SpyDirectory.fetch()
        async let web = try? SpyDirectory.fetchWeb()
        let (s, w) = await (spy, web)
        if s == nil && w == nil && hosts.isEmpty { hostsStatus = "Directory unavailable"; return }
        let keptSpy = s ?? hosts.filter { $0.network == .spyServer }
        let keptWeb = w ?? hosts.filter { $0.network == .webSDR }
        // A host can appear in both directories, and the id must stay unique.
        var seen = Set<String>()
        hosts = (keptSpy + keptWeb).filter { seen.insert($0.id).inserted }
        probeHosts()
        computeHostArrivals()
    }

    /// Checks everything in the background, publishing in batches so the list doesn't redraw per host.
    private func probeHosts() {
        probeTask?.cancel()
        let list = hosts.filter { !$0.listedOffline }
        enum Finding { case health(SpyHost, HostHealth), link(String, HostLink) }
        probeTask = Task {
            await withTaskGroup(of: Finding.self) { group in
                for h in list { group.addTask { .health(h, await HostProbe.check(h)) } }
                var batch: [(String, HostHealth?, HostLink?)] = []
                for await finding in group {
                    switch finding {
                    case .health(let h, let health):
                        // A host's status shows as soon as it's known, without waiting for its strength.
                        // A full host refuses the handshake but its path can still be measured.
                        if health == .answering || h.isFull {
                            batch.append((h.id, health, nil))
                            group.addTask { .link(h.id, await HostProbe.measureLink(host: h.host, port: h.port, background: h.network)) }
                        } else {
                            batch.append((h.id, health, HostLink(roundTripMs: nil, lost: 3)))
                        }
                    case .link(let id, let link):
                        batch.append((id, nil, link))
                    }
                    if batch.count >= 12 { publish(batch); batch = [] }
                }
                publish(batch)
            }
        }
    }
    private func publish(_ batch: [(String, HostHealth?, HostLink?)]) {
        // A host we're streaming from can refuse a second connection simply because we hold
        // its only slot, which says nothing about whether it's alive.
        let inUse = runner.isRunning ? selectedHostID : nil
        for (id, health, link) in batch where id != inUse {
            if let health { hostHealth[id] = health }
            if let link { hostLinks[id] = link }
        }
        if inUse == nil, let id = selectedHostID, let h = hostHealth[id] { hostReachable = h == .answering }
    }

    func status(of h: SpyHost) -> HostStatus {
        HostStatus.resolve(h, health: hostHealth[h.id], frequency: frequency, tooSlow: isTooSlow(h))
    }

    func isUsable(_ h: SpyHost) -> Bool { status(of: h) == .available }

    /// Available first, then unavailable, then dead. Alphabetical inside each group, so rows
    /// don't jump around when a location changes.
    func sortedHosts() -> [SpyHost] {
        let net = hostNetwork
        return HostRanking.sort(hosts.filter { $0.network == net }, near: hostSearchPlace) { status(of: $0) }
    }

    /// The current network's hosts around a clicked spot.
    func hostsAround(_ place: Station) -> HostRanking.Region {
        let net = hostNetwork
        return HostRanking.around(hosts.filter { $0.network == net }, place: place) { status(of: $0) }
    }

    /// Who can hear the locked satellite, in the order it reaches them.
    func hostsHearingLocked() -> [SpyHost] {
        let net = hostNetwork
        return HostPasses.listing(hosts.filter { $0.network == net }, arrivals: hostArrivals, frequency: frequency) { status(of: $0) }
    }

    /// Runs again whenever a satellite rises or sets over a listed host, so the rows stay true.
    private func computeHostArrivals() {
        hostArrivalTask?.cancel()
        nextArrivalChange = .distantFuture
        hostArrivalsReady = false
        guard hostsForSatellite, let clone = locked?.clone() else { hostArrivals = [:]; return }
        let net = hostNetwork
        // A host with no country has no real position, so nothing can be said about what it can see.
        let places = hosts.filter { $0.network == net && !$0.iso.isEmpty }.map { (id: $0.id, lat: $0.lat, lon: $0.lon) }
        let box = SendableSat(sat: clone)
        hostArrivalTask = Task.detached(priority: .utility) { [weak self] in
            let track = HostPasses.track(box.sat, from: Astro.julianDate())
            var found: [String: HostArrival] = [:]
            for p in places {
                if Task.isCancelled { return }
                found[p.id] = HostPasses.firstPass(on: track, ground: GroundPoint(lat: p.lat, lon: p.lon))
            }
            let result = found
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.hostArrivals = result
                self.hostArrivalsReady = true
                let now = Date()
                let changes = result.values.flatMap { [$0.aos, $0.los ?? .distantFuture] }.filter { $0 > now }
                self.nextArrivalChange = max(changes.min() ?? .distantFuture, now.addingTimeInterval(5))
            }
        }
    }

    // MARK: Pointing

    /// Saving noise wastes disk, but noise before a pass rises is just waiting. Automatic
    /// listening stays out of this, because it would only start again.
    private func stopIfOnlyNoise() {
        guard stopOnNoise, !autoListen, runner.isRunning, runner.mode == .record, runner.health.noiseSeconds >= 120,
              elevation.map({ $0 > 0 }) ?? true else { return }
        stopCapture()
        captureError = "Stopped: only noise for 2 minutes."
    }

    private func updateLook() {
        defer {
            runner.health.elevation = elevation
            stopIfOnlyNoise()
        }
        guard let st = station, let sat = lookSat else {
            azimuth = nil; elevation = nil; rangeKm = nil
            return
        }
        let jd = Astro.julianDate()
        guard let s = sat.state(jd: jd) else { return }
        let look = Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon)
        azimuth = look.az; elevation = look.el; rangeKm = look.range
    }

    private func computePass() {
        passTask?.cancel()
        guard let st = station, let clone = locked?.clone() else { pass = .unknown; return }
        pass = .computing
        let box = SendableSat(sat: clone)
        passTask = Task.detached(priority: .utility) { [weak self] in
            let result = Self.predict(box.sat, st)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.pass = result
                self?.followPass()
            }
        }
    }

    /// Keeps the pass current: in view once it rises, and the next one worked out once it sets,
    /// however many hours or days away that is.
    private func followPass() {
        guard case .pass(let p) = pass else { return }
        let norad = locked?.norad
        passTask = Task { [weak self] in
            if !p.inProgress {
                try? await Task.sleep(for: .seconds(max(0, p.aos.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self, self.locked?.norad == norad else { return }
                var now = p; now.inProgress = true
                self.pass = .pass(now)
            }
            try? await Task.sleep(for: .seconds(max(0, p.los.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled, let self, self.locked?.norad == norad else { return }
            self.computePass()
        }
    }

    /// Steps forward up to three days, refining AOS/LOS to the second by bisection.
    nonisolated static func predict(_ sat: Satellite, _ st: Station) -> PassState {
        func el(_ jd: Double) -> Double {
            guard let s = sat.state(jd: jd) else { return -90 }
            return Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon).el
        }
        func refine(_ a: Double, _ b: Double, rising: Bool) -> Double {
            var lo = a, hi = b
            for _ in 0..<12 {
                let m = (lo + hi) / 2
                if (el(m) > 0) == rising { hi = m } else { lo = m }
            }
            return hi
        }
        func date(_ jd: Double) -> Date { Date(timeIntervalSince1970: (jd - 2440587.5) * 86400) }

        let start = Astro.julianDate()
        let step = min(60.0, max(15.0, sat.periodMinutes * 60 / 120)) / 86400
        let horizon = start + 3
        var t = start
        var up = el(t) > 0
        let wasUp = up
        var aos: Double? = up ? start : nil
        var maxEl = up ? el(t) : -90.0
        while t < horizon {
            if Task.isCancelled { return .unknown }
            let next = t + step
            let e = el(next)
            let nowUp = e > 0
            if nowUp && !up { aos = refine(t, next, rising: true) }
            if nowUp { maxEl = max(maxEl, e) }
            if up && !nowUp, let a = aos {
                return .pass(PassInfo(aos: date(a), los: date(refine(t, next, rising: false)),
                                      maxElevation: maxEl, inProgress: wasUp && a == start))
            }
            up = nowUp
            t = next
        }
        if aos == start { return .alwaysVisible }
        return .none
    }

    // MARK: Capture

    var canCapture: Bool {
        guard runner.executable != nil, locked != nil, frequency != nil, !source.browserOnly else { return false }
        if rangeProblem != nil { return false }
        if source.addressFlag != nil, address.isEmpty { return false }
        return true
    }

    private var currentListenKey: ListenKey? {
        guard let sat = locked, let f = frequency else { return nil }
        if listenOutput == .decode, pipeline == nil { return nil }
        return ListenKey(norad: sat.norad, frequency: f + signalOffsetHz, pipeline: listenOutput == .decode ? pipeline?.id ?? "" : "", source: sourceID,
                         address: address, port: port, sampleRate: sampleRate, output: listenOutput, agc: agcActive, ppm: ppm)
    }

    // MARK: Frequency corrections

    @Published private var ppmBySource = UserDefaults.standard.dictionary(forKey: "ppmBySource") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(ppmBySource, forKey: "ppmBySource") }
    }
    @Published private var signalOffsets = UserDefaults.standard.dictionary(forKey: "signalOffsets") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(signalOffsets, forKey: "signalOffsets") }
    }

    /// The current receiver's clock error. Remembered per source, as it belongs to the hardware.
    var ppm: Double {
        get { ppmBySource[sourceID] ?? 0 }
        set { ppmBySource[sourceID] = newValue == 0 ? nil : max(-200, min(200, newValue)) }
    }

    private var offsetKey: String? {
        guard let sat = locked, let f = frequency else { return nil }
        return FrequencyCorrection.key(norad: sat.norad, hz: f)
    }

    /// How far this satellite's signal really is from its listed frequency, saved per signal.
    var signalOffsetHz: Double {
        get { offsetKey.flatMap { signalOffsets[$0] } ?? 0 }
        set { if let k = offsetKey { signalOffsets[k] = newValue == 0 ? nil : max(-50_000, min(50_000, newValue)) } }
    }

    func savedOffset(norad: Int, hz: Double) -> Double { signalOffsets[FrequencyCorrection.key(norad: norad, hz: hz)] ?? 0 }

    /// Bytes per second a raw capture writes, for the chosen sample format.
    var fileBytesPerSecond: Double {
        let perSample: Double
        switch effectiveFormat {
        case "cf32", "cs32": perSample = 8
        case "cs8", "cu8": perSample = 2
        default: perSample = 4
        }
        return sampleRate * perSample
    }

    var fileRateText: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileBytesPerSecond), countStyle: .file) + "/s"
    }

    private var freeBytes: Int64 {
        let dir = FileManager.default.fileExists(atPath: outputDir.path) ? outputDir : outputDir.deletingLastPathComponent()
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
    }
    private static let startSpace: Int64 = 5_000_000_000
    private static let stopSpace: Int64 = 2_000_000_000

    /// nil when listening can go ahead, otherwise what it's waiting for.
    /// Why the start button is greyed out, in the same order it checks. Nil means it isn't.
    var startProblem: StartProblem? {
        guard !runner.isRunning, !isPreparing else { return nil }
        if let rangeProblem { return StartProblem(message: rangeProblem) }
        return StartProblem.check(satellite: locked?.name, encryption: locked?.encryption.state, engineMissing: runner.executable == nil,
                                  browserOnly: source.browserOnly, hasFrequency: frequency != nil, decoding: listenOutput == .decode,
                                  hasDecoder: pipeline != nil, needsAddress: source.addressFlag != nil && address.isEmpty, isSpy: source.kind == .spy)
    }

    private func listenBlocker() -> String? {
        guard let sat = locked else { return "Lock a satellite to start listening" }
        if runner.executable == nil { return "The receiving engine is missing" }
        guard let f = frequency else { return "No public frequency for \(sat.name)" }
        let p = pipeline
        if listenOutput == .decode, p == nil { return "No decoder for this satellite. Save to file works." }
        if listenOutput == .file, !runner.isRunning, freeBytes < Self.startSpace { return "Less than 5 GB of disk free" }
        if source.browserOnly { return "This network only opens in a browser" }
        if let rangeProblem { return rangeProblem }
        switch source.kind {
        case .spy:
            guard let h = selectedHost else { return "Pick a spy host" }
            if connection == .failed { return "This host isn't connecting. Pick another." }
            if connection != .connected { return "Connecting to the host…" }
            guard status(of: h) == .available else {
                if !h.covers(f) { return "This host can't tune \(formatHz(f))" }
                if h.isFull { return "This host is full" }
                if isTooSlow(h) { return "This host's connection is too slow for this signal" }
                return "This host's owner restricts retuning"
            }
            // Analog audio needs far less than the rate it asks for, so only symbols set a hard limit.
            if let p, h.maxSampleRate < (p.symbolRate ?? 0) * 2, listenOutput == .decode { return "This host's bandwidth is too narrow for \(p.name)" }
        case .network:
            if address.isEmpty { return "Enter the source address" }
        case .usb:
            if attachedDevice(for: source) == nil {
                return "Connect a \(source.name)"
            }
        }
        // Keep going slightly below the horizon, so a satellite right at it doesn't flip on and off.
        if let el = elevation {
            let threshold = runner.isRunning ? -0.5 : 0.0
            if el <= threshold {
                if el < -0.5 { stoppedByUser = nil }
                if case .pass(let pass) = self.pass, pass.aos > Date() {
                    let minutes = Int(pass.aos.timeIntervalSinceNow / 60)
                    return minutes < 1 ? "Waiting: rises in under a minute" : "Waiting: rises in \(minutes) min"
                }
                return "Waiting for \(sat.name) to rise here"
            }
        }
        return nil
    }

    /// Follows the tracked satellite once a second: starts when it's in view, restarts when
    /// anything about it changes, and stops when it sets.
    func autoListenTick() {
        if !runner.isRunning { stopIssued = false }

        // A run that ended by itself: a failure backs off for a minute before trying again.
        if !runner.isRunning, !isPreparing, let key = listeningKey {
            if captureError != nil || runner.lastError != nil {
                failedKey = key
                retryAt = Date().addingTimeInterval(60)
                if source.kind == .spy { connection = .failed }
            }
            listeningKey = nil
        }
        if runner.isStreaming, source.kind == .spy, connection != .connected { connection = .connected }

        let blocker = listenBlocker()
        let key = currentListenKey
        var text = blocker ?? ""

        // A raw capture stops before it fills the disk, however it was started.
        if runner.mode == .record, linkTick % 5 == 0, freeBytes < Self.stopSpace {
            stoppedByUser = key
            stopOnce()
            captureError = "Stopped saving: less than 2 GB of disk free."
        }

        // Decoding or raw, the limit is on everything the capture has written.
        if runner.isRunning, !runner.isProcessing, let limit = sizeLimitMB, let dir = runner.outputDir,
           Self.folderBytes(dir) >= Int64(limit) * 1_000_000 {
            stoppedByUser = key
            stopOnce()
            captureNote = "Stopped at the \(limit) MB limit."
        }

        if !autoListen {
            text = ""
            if blocker == nil, runner.isRunning, let listeningKey, listeningKey != key { stopOnce() }
        } else if blocker == nil, let key {
            if runner.isRunning {
                if runner.isProcessing {
                    text = "Processing results…"
                } else if listeningKey != key {
                    stopOnce()
                    text = "Retuning…"
                } else {
                    text = listenOutput == .decode ? "Decoding automatically" : "Saving to file automatically, about \(fileRateText)"
                }
            } else if isPreparing {
                text = "Contacting the host…"
            } else if stoppedByUser == key {
                text = "Stopped. Press Listen to resume."
            } else if failedKey == key, Date() < retryAt {
                text = "Couldn't start. Trying again shortly."
            } else {
                stoppedByUser = nil
                startCapture(listenOutput.captureMode)
                text = "Starting…"
            }
        } else if runner.isRunning, listeningKey != nil {
            stopOnce()
        }
        if text != autoStatus { autoStatus = text }
    }

    private static func folderBytes(_ folder: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    private func stopOnce() {
        guard !stopIssued else { return }
        stopIssued = true
        losStopTimer?.invalidate()
        runner.stop()
    }

    func startCapture(_ mode: CaptureMode) {
        guard !isPreparing else { return }
        captureError = nil
        captureNote = nil
        listeningKey = currentListenKey
        stoppedByUser = nil
        guard source.addressFlag != nil, source.defaultPort != nil else { launch(mode); return }
        // Just measured too slow: a retest right away may only find its slot still busy, and prove nothing.
        if matchesHost, let h = selectedHost, isTooSlow(h) {
            captureError = "This host's connection is too slow for this signal. Pick another host."
            return
        }
        isPreparing = true
        Task {
            var ok: Bool
            if source.kind == .spy, let h = selectedHost {
                let result = await HostProbe.checkNow(h)
                hostHealth[h.id] = result
                ok = result == .answering
                // A full host has no slot for a test, and SatDump will say so itself.
                if ok, matchesHost, !h.isFull, let f = frequency {
                    let want = rate(on: h)
                    let need = want * 2
                    testingSpeed = true
                    let delivered = await HostProbe.throughput(h, sampleRate: want, frequency: f)
                    testingSpeed = false
                    if let delivered, delivered < need * Self.enoughDelivered {
                        slowHosts[h.id] = (delivered, Date())
                        isPreparing = false
                        hostReachable = true
                        func speed(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) + "/s" }
                        captureError = "This host delivers \(speed(delivered)), and this signal needs \(speed(need)). Pick another host."
                        return
                    }
                    if delivered != nil { slowHosts[h.id] = nil }
                }
                // Give a one-client server a moment to free the slot the check just used.
                if ok { try? await Task.sleep(for: .milliseconds(500)) }
            } else {
                ok = await HostProbe.connects(host: address, port: port)
            }
            isPreparing = false
            if source.kind == .spy { hostReachable = ok }
            if ok { launch(mode) } else { captureError = "\(address):\(port) is not answering. Pick another host." }
        }
    }

    /// Settings the analog demodulator needs: it has no way to learn these from the signal.
    private func pipelineArgs(_ sat: Satellite, frequency f: Double) -> [String] {
        guard pipeline?.id == "analog_demod" else { return [] }
        let mode = (sat.transmitters.first { $0.downlinkHz == f } ?? sat.primaryDownlink)?.mode.uppercased() ?? "FM"
        let am = mode.hasPrefix("AM") || mode.hasPrefix("SSB") || mode.hasPrefix("USB") || mode.hasPrefix("LSB") || mode.hasPrefix("CW")
        return ["--modulation_type", am ? "AM" : "NFM",
                "--satellite_norad", String(sat.norad),
                "--satellite_frequency", String(Int64(f))]
    }

    /// The AGC setup for the current source, if it has one and the installed SatDump confirms it.
    var agcSpec: AGCSpec? {
        guard runner.agcConfirmed.contains(sourceID) else { return nil }
        return SDRCatalog.agc[sourceID]
    }

    var agcActive: Bool { agcSpec != nil && agcChoices[sourceID] == true }

    var agcBinding: Binding<Bool> {
        Binding(get: { self.agcActive }, set: { self.agcChoices[self.sourceID] = $0 })
    }

    /// True when the gain slider no longer does anything.
    var agcReplacesGain: Bool { agcActive && agcSpec?.replacesGain == true }

    /// A spy server works out its own digital gain unless it's been set by hand.
    private var sendsGain: Bool { source.gainFlag != nil && (source.kind != .spy || gainIsManual) && !agcReplacesGain }

    private func launch(_ mode: CaptureMode) {
        rtlProbe.cancel()
        guard let sat = locked, let listed = frequency else { return }
        let f = listed + signalOffsetHz
        runner.start(CaptureRequest(
            mode: mode, source: source, address: address, port: port, pipelineID: pipeline?.id,
            frequencyHz: f, sampleRate: sampleRate, gain: sendsGain ? gain : nil,
            bias: bias, bitDepth: effectiveBitDepth, basebandFormat: effectiveFormat, dcBlock: dcBlock, iqSwap: iqSwap,
            // The analog demodulator's audio needs no further processing.
            finishProcessing: finishProcessing && pipeline?.id != "analog_demod", outputDir: outputDir, label: [sat.name, activeMedia?.kind.rawValue].compactMap { $0 }.joined(separator: " "),
            extraArgs: pipelineArgs(sat, frequency: f), norad: sat.norad, pipelineName: pipeline?.name, formatName: listedFormat?.rawValue,
            hostLabel: source.kind == .spy ? selectedHost?.placeName : (address.isEmpty ? nil : address),
            sourceArgs: (agcActive ? agcSpec?.args ?? [] : []) + FrequencyCorrection.arguments(source: sourceID, ppm: ppm),
            dialHz: FrequencyCorrection.requested(f, source: sourceID, ppm: ppm)))
        losStopTimer?.invalidate()
        if stopAtLOS, case .pass(let p) = pass, p.los > Date() {
            losStopTimer = Timer.scheduledTimer(withTimeInterval: p.los.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.runner.stop() }
            }
        }
    }

    func stopCapture() {
        losStopTimer?.invalidate()
        stoppedByUser = currentListenKey
        runner.stop()
    }
}

private struct SendableSat: @unchecked Sendable { let sat: Satellite }

/// Native location completion, for typing a base station.
@MainActor
final class LocationCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address]
    }

    /// A reply can arrive after a choice was made, and must not bring the list back.
    private var wanted = false

    func update(_ q: String) {
        wanted = !q.trimmingCharacters(in: .whitespaces).isEmpty
        if q.trimmingCharacters(in: .whitespaces).isEmpty { results = []; completer.cancel() }
        else { completer.queryFragment = q }
    }

    func clear() {
        wanted = false
        results = []
        completer.cancel()
    }

    nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        let r = Array(c.results.prefix(6))
        Task { @MainActor in if self.wanted { self.results = r } }
    }

    nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> (String, CLLocationCoordinate2D, String)? {
        let req = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: req).start(), let item = response.mapItems.first else { return nil }
        let name = completion.title
        return (name, item.placemark.coordinate, (item.placemark.isoCountryCode ?? "").lowercased())
    }
}
