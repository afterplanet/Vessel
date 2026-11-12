import SwiftUI
import AppKit
import SceneKit
import MapKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?

    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ n: Notification) {
        // A plain kill should still shut SatDump down rather than leave it recording to disk.
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { NSApp.terminate(nil) }
        s.resume()
        termSource = s
        // Lets a plain `swift run` come to the front like a real app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { onQuit?() }
}

@main
struct VesselApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SatelliteStore()
    @StateObject private var runner: SatDumpRunner
    @StateObject private var app: AppState
    @StateObject private var tx: TransmitController
    @StateObject private var rotator: RotatorController
    @StateObject private var updates = DataUpdates()
    @StateObject private var radar = RadarTracker()
    @StateObject private var planner = PassPlanner()
    @StateObject private var results = ResultsStore()

    init() {
        if let i = Snapshot.arguments.firstIndex(of: "--fail-textures"), let n = Int(Snapshot.arguments[i + 1]) { GlobeRenderer.failedLoadsForTesting = n }
        // Restoring a killed session can leave the app with no window at all, and there is nothing worth restoring.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        let r = SatDumpRunner()
        _runner = StateObject(wrappedValue: r)
        let a = AppState(runner: r)
        _app = StateObject(wrappedValue: a)
        _tx = StateObject(wrappedValue: TransmitController(app: a))
        _rotator = StateObject(wrappedValue: RotatorController(app: a))
    }

    var body: some Scene {
        Window("Vessel", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(runner)
                .environmentObject(app)
                .environmentObject(tx)
                .environmentObject(rotator)
                .environmentObject(updates)
                .environmentObject(radar).environmentObject(planner)
                .environmentObject(results)
                .frame(minWidth: 980, minHeight: 620)
                .background(TitleAtFarLeft())
                .preferredColorScheme(.dark)
                .onAppear { delegate.onQuit = { [weak runner, weak tx, weak rotator] in
                    MainActor.assumeIsolated {
                        SatDumpScanFeed.stopAll()
                        tx?.shutdown()
                        rotator?.shutdown()
                        runner?.stopForQuit()
                    }
                } }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands(app: app, runner: runner, tx: tx, rotator: rotator, store: store, updates: updates)
        }

        Window("Results", id: "results") {
            ResultsView()
                .environmentObject(results)
                .environmentObject(app)
                .environmentObject(runner)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 700)

        // App menu, Settings: the same place to update data by hand.
        Settings {
            DataUpdatesView()
                .environmentObject(updates)
                .environmentObject(store)
                .environmentObject(app)
                .environmentObject(runner)
                .preferredColorScheme(.dark)
        }

        Window("Data Updates", id: "data") {
            DataUpdatesView()
                .environmentObject(updates)
                .environmentObject(store)
                .environmentObject(app)
                .environmentObject(runner)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

final class GlobeSizeBox: ObservableObject {
    @Published var size = CGSize(width: 1100, height: 800)
}

/// Follows the globe's size by itself, so only the spectrum redraws as the window changes.
struct SpectrumSlot: View {
    @ObservedObject var box: GlobeSizeBox
    let feed: SpectrumFeed
    var labels: WaterfallLabels? = nil
    var lockedID: Int? = nil
    var onPick: (SpectrumMark) -> Void = { _ in }
    let close: () -> Void

    var body: some View {
        SpectrumPanel(feed: feed, available: box.size, onClose: close, labels: labels, lockedID: lockedID, onPick: onPick)
            .padding(.trailing, 12)
            // Beside the address bar if there's room, below it if not.
            .padding(.top, box.size.width >= 1040 ? 12 : 56)
    }
}

/// The app's name right beside the window controls. A titlebar accessory stays there whatever
/// the sidebar does, and it isn't a toolbar item, so it can't upset the toolbar's layout.
struct TitleAtFarLeft: NSViewRepresentable {
    final class Probe: NSView {
        private var added = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !added else { return }
            added = true
            let label = NSTextField(labelWithString: "Vessel")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
            label.sizeToFit()
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 14, height: 28))
            label.frame.origin = NSPoint(x: 4, y: (holder.frame.height - label.frame.height) / 2)
            label.autoresizingMask = [.minYMargin, .maxYMargin]
            holder.addSubview(label)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = holder
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {}
}

/// Spelled out on hover, because the short forms aren't obvious.
private struct LegendTip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .allowsHitTesting(false)
    }
}

struct RootView: View {
    @EnvironmentObject var store: SatelliteStore
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var tx: TransmitController
    @EnvironmentObject var rotator: RotatorController
    @EnvironmentObject var radar: RadarTracker
    @EnvironmentObject var planner: PassPlanner
    @StateObject private var signalLabels = WaterfallLabels()
    @StateObject private var schedule = PassSchedule()
    @StateObject private var groups = SatelliteGroups()
    @State private var showSpacecraftList = Snapshot.arguments.contains("--spacecraft-list")
    @EnvironmentObject var results: ResultsStore
    @State private var query = ""
    @Environment(\.openWindow) private var openWindow
    @State private var legendHover = Snapshot.arguments.firstIndex(of: "--legend-tip").flatMap { OrbitClass(rawValue: Snapshot.arguments[$0 + 1]) }
    // Not observed here: the sidebar's slide changes this on every frame, and redrawing the
    // whole window (toolbar included) that often is what fed the freeze.
    @State private var globeSize = GlobeSizeBox()
    @State private var lastSidebarToggle: CFTimeInterval = 0
    @State private var sidebar = NavigationSplitViewVisibility.all
    /// Scripted checks open straight into the app, unless they ask to see the checklist.
    @State private var showStartup = Snapshot.arguments.isEmpty || Snapshot.arguments.contains("--startup")

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            ScrollView {
                VStack(spacing: 0) {
                    StackPanel(title: "Satellite", symbol: "cube.transparent") { SatelliteSection() }
                    StackPanel(title: "Passes", symbol: "calendar.badge.clock") { PassesSection() }
                    StackPanel(title: "Groups", symbol: "folder.badge.person.crop") { GroupsSection(groups: groups, schedule: schedule) }
                    if app.panelMode == .receive {
                        StackPanel(title: "Listener", symbol: "antenna.radiowaves.left.and.right") { ListenerSection() }
                        StackPanel(title: "Capture", symbol: "waveform") { CaptureSection() }
                        StackPanel(title: "Schedule", symbol: "list.bullet.clipboard") { ScheduleSection(schedule: schedule) }
                        StackPanel(title: "Output", symbol: "photo.on.rectangle") {
                            OutputSection(health: runner.health, spectrum: runner.spectrum)
                        }
                    } else {
                        StackPanel(title: "Transmit", symbol: "dot.radiowaves.up.forward") { TransmitSection() }
                        StackPanel(title: "Contact planner", symbol: "person.2.wave.2") { ContactPlannerSection() }
                        StackPanel(title: "Contact log", symbol: "list.bullet.rectangle") { ContactLogSection() }
                    }
                }
            }
            // The system's button can't have items placed before it, so this toolbar draws its own.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
        } detail: {
            // Inside the safe area, so the globe centres on what's visible rather than behind the sidebar.
            ZStack {
            GlobeView()
                .overlay(alignment: .top) { LocationBar().padding(.top, 12) }
                .overlay(alignment: .topLeading) { countBadge.padding(12) }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Imagery: Sentinel-2 cloudless 2016 by EOX, Copernicus Sentinel data; NASA Blue Marble")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                            .shadow(color: .black, radius: 2)
                            .allowsHitTesting(false)
                        // Side by side if there's room beside the radar, stacked if not.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                legend
                                filterBar
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                filterBar
                                legend
                            }
                        }
                        .padding(.trailing, 270)
                    }
                    .padding(12)
                }
                .overlay(alignment: .bottomTrailing) { RadarPanel(startExpanded: Snapshot.arguments.contains("--radar-open"), overheadOpen: Snapshot.arguments.contains("--overhead-open")).padding(12) }
                .overlay { globeStatus }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 8) {
                        if app.showSpectrum {
                            SpectrumSlot(box: globeSize, feed: runner.spectrum, labels: signalLabels, lockedID: app.locked?.norad, onPick: tune) { app.showSpectrum = false }
                        }
                        searchResults
                    }
                }
                if let object = app.spaceObject { SpaceSceneOverlay(object: object).id(object.id) }
            }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { globeSize.size = $0 }
        }
        .overlay {
            if showStartup { StartupChecklist(isPresented: $showStartup).transition(.opacity) }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Find satellite or NORAD ID")
        .onSubmit(of: .search) {
            if let first = store.search(query).first { select(first) }
        }
        // One fixed set of items in one place. Adding and removing them as the sidebar opened and
        // closed sent AppKit's toolbar layout into a loop that froze the app.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { app.panelMode = app.panelMode.other } label: {
                    Label(app.panelMode.other.buttonTitle, systemImage: app.panelMode.other.symbol)
                        .labelStyle(.titleAndIcon)
                        .frame(width: 104)
                }
                .help("Switch the sidebar to \(app.panelMode.other.buttonTitle.lowercased())")
                Button { toggleSidebar() } label: {
                    Label("Sidebar", systemImage: "sidebar.left")
                }
                .help(sidebar == .detailOnly ? "Show sidebar" : "Hide sidebar")
                SavedFilesButton()
            }
            ToolbarItem(placement: .primaryAction) { LockHistoryButton() }
        }
        .task {
            radar.start()
            radar.setStation(app.station)
            // Open facing the saved address, since its marker would otherwise often be out of sight.
            app.flyToStation()
            // In the background at every start: a slow or missing network must not hold anything up.
            Task { await runner.checkForPipelineUpdates(); app.retune() }
            // Side by side: a slow host directory must not hold up the satellites.
            async let hosts: Void = app.refreshHosts()
            await store.load()
            await hosts
            // Orbit data goes stale over a long session. Checks quietly, and only fetches what's due.
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                    if (DataUpdates.age(of: "gp_active.json") ?? .infinity) >= 7200 { _ = await store.reload(force: true) }
                }
            }
            Self.runScriptedLaunch(store: store, app: app, tx: tx, rotator: rotator, radar: radar, results: results)
            TxSelfTest.runIfRequested(store: store, app: app, tx: tx)
        }
        .onChange(of: store.enrichmentVersion) { _, _ in
            // Frequencies may arrive after a lock: redo the automatic choice unless one was made by hand.
            if app.pipelineOverrideID == nil, app.frequencyOverride == nil { app.retune() }
            tx.refreshUplinks(app.locked)
            store.refreshFrequencies(catalog: runner.catalog)
            syncRadarFilter()
        }
        .onChange(of: store.catalogVersion) { _, _ in
            store.setReceiverRanges(app.receiverRanges)
            store.applyFilter(app.satelliteFilter); syncRadarFilter()
            store.refreshFrequencies(catalog: runner.catalog)
            // Fresh orbits mean new objects: keep the same satellite locked, without disturbing a capture.
            if let n = app.locked?.norad, let fresh = store.satellite(norad: n) { app.refreshLocked(fresh) }
            radar.setSatellites(store.satellites)
            syncRadarFilter()
            schedule.recompute()
        }
        // Pass times for a spacecraft locked before its position arrived.
        .onChange(of: store.positionsVersion) { _, _ in
            if let locked = app.locked, locked.ephemeris != nil { app.refreshLocked(locked) }
        }
        .onChange(of: app.toggleSidebarRequest) { _, _ in toggleSidebar() }
        .onChange(of: app.showSidebarRequest) { _, _ in if sidebar == .detailOnly { withAnimation { sidebar = .all } } }
        .onChange(of: app.satelliteFilter) { _, f in store.applyFilter(f); syncRadarFilter() }
        .onChange(of: app.receiverRanges) { _, ranges in
            store.setReceiverRanges(ranges)
            app.moveToReachableDownlink()
        }
        .sheet(isPresented: $app.showScan) {
            if let sat = app.locked {
                ScanSheet(satellite: sat).environmentObject(app).environmentObject(runner)
            } else {
                // Never leave an empty sheet with no way out.
                Color.clear.frame(width: 1, height: 1).onAppear { app.showScan = false }
            }
        }
        .task {
            // VESSEL_TEST="--sidebar-stress N" flips the sidebar quickly, as repeated clicks do.
            let a = Snapshot.arguments
            guard let i = a.firstIndex(of: "--sidebar-stress"), let n = Int(a[i + 1]) else { return }
            let gap = a.firstIndex(of: "--stress-gap").flatMap { Double(a[$0 + 1]) } ?? 0.08
            try? await Task.sleep(for: .seconds(5))
            var worst = 0.0
            for k in 0..<n {
                let before = CACurrentMediaTime()
                withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
                if a.contains("--stress-mode"), k % 3 == 0 { app.panelMode = app.panelMode == .receive ? .transmit : .receive }
                try? await Task.sleep(for: .seconds(gap))
                // The sleep can only overrun if the main thread was stuck.
                worst = max(worst, CACurrentMediaTime() - before - gap)
                if k % 40 == 0 { FileHandle.standardError.write(Data(String(format: "stress %d worst stall %.2f s\n", k, worst).utf8)) }
            }
            FileHandle.standardError.write(Data(String(format: "stress done worst stall %.2f s\n", worst).utf8))
        }
        .onChange(of: app.locked?.norad) { _, _ in
            tx.satelliteChanged(app.locked)
            planner.update(satellite: app.locked, station: app.station)
        }
        // Switching mode is pointless with the panels hidden.
        .onChange(of: app.panelMode) { _, _ in if sidebar == .detailOnly { withAnimation { sidebar = .all } } }
        .onAppear {
            Snapshot.livePlanner = planner
            signalLabels.attach(store: store, app: app)
            schedule.attach(store: store, app: app)
            Snapshot.liveSchedule = schedule
        }
        .onChange(of: app.showSpectrum) { _, _ in signalLabels.refresh() }
        .onChange(of: groups.shownNorads) { _, only in app.satelliteFilter.onlyNorads = only }
        .onChange(of: app.station) { _, s in
            radar.setStation(s)
            planner.update(satellite: app.locked, station: s)
        }
    }

    /// Tells the radar which satellites the filters hide, so it leaves them out of what's approaching.
    private func syncRadarFilter() {
        radar.setHidden(Set(store.satellites.lazy.filter(\.filteredOut).map(\.norad)))
    }

    /// A name clicked on the spectrum: lock that satellite and tune to the signal that was named.
    private func tune(_ label: SpectrumMark) {
        guard let sat = store.satellite(norad: label.norad) else { return }
        if app.locked?.norad != sat.norad { app.lock(sat) }
        app.frequencyOverride = label.nominalHz
    }

    /// The number of satellites showing, so it follows the type filter.
    private var countBadge: some View {
        Text(countText)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .opacity(0.5)
            .allowsHitTesting(false)
    }

    private var countText: String {
        guard !store.satellites.isEmpty else { return store.status }
        if let f = app.orbitFilter { return "\(store.shownCount(of: f).formatted()) \(f.rawValue) satellites" }
        return "\(store.shownCount(of: nil).formatted()) satellites"
    }

    /// The globe says so while it's loading or in trouble, rather than sitting there blank.
    @ViewBuilder private var globeStatus: some View {
        if !app.globeReady || app.globeProblem != nil {
            HStack(spacing: 8) {
                if app.globeProblem?.contains("couldn't") != true { ProgressView().controlSize(.small) }
                Text(app.globeProblem ?? "Loading the globe…").font(.system(size: 12))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .allowsHitTesting(false)
        }
    }

    /// Clicks during the slide are ignored, so a burst of them can't pile up animations.
    private func toggleSidebar() {
        let now = CACurrentMediaTime()
        guard now - lastSidebarToggle > 0.3 else { return }
        lastSidebarToggle = now
        withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
    }

    private func select(_ s: Satellite) {
        app.lock(s)
        query = ""
    }

    /// `VESSEL_TEST="--lock <norad> --host <n> ..."` opens the app in a known state, for scripted checks.
    @MainActor private static func runScriptedLaunch(store: SatelliteStore, app: AppState, tx: TransmitController, rotator: RotatorController, radar: RadarTracker, results: ResultsStore) {
        let a = Snapshot.arguments
        func value(_ flag: String) -> String? {
            a.firstIndex(of: flag).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
        }
        if let v = value("--lock"), let n = Int(v), let s = store.satellite(norad: n) { app.lock(s) }
        if let v = value("--host"), let i = Int(v) {
            let usable = app.sortedHosts().filter(app.isUsable)
            if usable.indices.contains(i) { app.selectHost(usable[i]) }
        }
        if let v = value("--host-addr"), let h = app.hosts.first(where: { $0.host == v }) { app.selectHost(h) }
        if a.contains("--host-report") {
            Task {
                try? await Task.sleep(for: .seconds(Double(value("--host-report-after") ?? "25") ?? 25))
                for (id, net) in [("spyserver", SpyHost.Network.spyServer), ("websdr", .webSDR)] {
                    app.sourceID = id
                    let list = app.sortedHosts()
                    let st = list.map(app.status(of:))
                    let order = st == st.sorted()
                    let n = { (s: HostStatus) in st.filter { $0 == s }.count }
                    FileHandle.standardError.write(Data("hosts \(net): total=\(list.count) available=\(n(.available)) unavailable=\(n(.unavailable)) dead=\(n(.dead)) checking=\(n(.checking)) sortedOK=\(order)\n".utf8))
                    FileHandle.standardError.write(Data("  available: \(list.filter { app.status(of: $0) == .available }.prefix(8).map { "\($0.host):\($0.port)" }.joined(separator: " "))\n".utf8))
                }
                app.sourceID = "spyserver"
                if let h = app.sortedHosts().first {
                    let before = (app.renderer?.lon, app.renderer?.lat)
                    app.selectHost(h)
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write(Data("selected \(h.host) at \(h.lat),\(h.lon); station=\(app.station?.name ?? "-") \(app.station?.lat ?? 0),\(app.station?.lon ?? 0) flag=\(app.station?.iso ?? "-") camera \(before) -> (\(app.renderer?.lon ?? 0), \(app.renderer?.lat ?? 0))\n".utf8))
                }
            }
        }
        if let v = value("--zoom"), let z = Float(v) { app.renderer?.targetDistance = z }
        if let v = value("--filter") { app.orbitFilter = OrbitClass(rawValue: v) }
        if let i = a.firstIndex(of: "--click-stress"), let n = Int(a[i + 1]) {
            Snapshot.clickStress(count: n, gap: a.firstIndex(of: "--stress-gap").flatMap { Double(a[$0 + 1]) } ?? 0.15)
        }
        if let v = value("--filter-country") { app.satelliteFilter.country = v.replacingOccurrences(of: "_", with: " ") }
        if a.contains("--country-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(14))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                log("countries: \(store.countries.count). Largest: \(store.countries.sorted { $0.count > $1.count }.prefix(7).map { "\($0.name) \($0.count)" })")
                let listed = store.countries.reduce(0) { $0 + $1.count }
                let unmapped = Dictionary(grouping: store.satellites.filter { $0.countryISO.isEmpty }, by: \.ownerCode).mapValues(\.count).sorted { $0.value > $1.value }.prefix(12)
                log("in the menu: \(listed) of \(store.satellites.count). Not in it: \(unmapped.map { "\($0.key):\($0.value)" })")
                for name in ["India", "Japan", "China", "Russia", "United Kingdom"] {
                    app.satelliteFilter = SatelliteFilter(country: name)
                    try? await Task.sleep(for: .milliseconds(200))
                    log("country \(name): \(store.shownCount(of: nil)) shown")
                }
                app.satelliteFilter = SatelliteFilter(year: 2024, country: "India")
                try? await Task.sleep(for: .milliseconds(200))
                log("India launched 2024: \(store.shownCount(of: nil)) shown")
                app.satelliteFilter = SatelliteFilter()
                log("country done")
            }
        }
        if let v = value("--filter-year"), let y = Int(v) { app.satelliteFilter.year = y }
        if let v = value("--filter-enc"), let e = TriFilter(rawValue: v) { app.satelliteFilter.encryption = e }
        if let v = value("--filter-freq"), let e = TriFilter(rawValue: v) { app.satelliteFilter.frequency = e }
        if a.contains("--filter-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                @MainActor func report(_ name: String) { FileHandle.standardError.write(Data("filter \(name): \(store.shownCount(of: nil)) shown, LEO \(store.shownCount(of: .leo))\n".utf8)) }
                report("none")
                for (name, f) in [("year2024", SatelliteFilter(year: 2024)), ("encYes", SatelliteFilter(encryption: .yes)), ("encNo", SatelliteFilter(encryption: .no)),
                                  ("freqYes", SatelliteFilter(frequency: .yes)), ("freqNo", SatelliteFilter(frequency: .no)),
                                  ("2024,freqYes", SatelliteFilter(year: 2024, frequency: .yes))] {
                    app.satelliteFilter = f
                    try? await Task.sleep(for: .milliseconds(300))
                    report(name)
                }
                app.satelliteFilter = SatelliteFilter()
                FileHandle.standardError.write(Data("filter done\n".utf8))
            }
        }
        if a.contains("--open-scan") { app.showScan = true }
        if let path = value("--model-sheet") { Snapshot.modelSheet(to: path, extra: value("--model-extra")) }
        if let v = value("--scan-use"), let hz = Double(v), let sat = app.locked {
            let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
            log("before: freq=\(app.frequency ?? 0) problem=\(app.startProblem?.message ?? "-")")
            app.useScannedFrequency(hz * 1e6, for: sat)
            log("after use: freq=\(app.frequency ?? 0) found=\(app.scanFrequency(for: sat) ?? 0) problem=\(app.startProblem?.message ?? "-")")
            app.retune()
            log("after retune: freq=\(app.frequency ?? 0)")
            app.listenOutput = .file
            log("save to file: problem=\(app.startProblem?.message ?? "-") rate=\(Int(app.sampleRate))")
            app.listenOutput = .decode
            app.forgetScannedFrequency(for: sat)
            log("after forget: freq=\(app.frequency ?? 0)")
        }
        if let i = a.firstIndex(of: "--scan-test") {
            // "low-high" in MHz. Locks the satellite named, or finds a busy one overhead at the host.
            Snapshot.scanTest(band: a[i + 1], seconds: value("--scan-seconds").flatMap { Double($0) } ?? 90, prefix: value("--scan-sat"), app: app, store: store)
        }
        if let v = value("--source") { app.sourceID = v }
        if let v = value("--address") { app.address = v }
        if let v = value("--port"), let n = Int(v) { app.port = n }
        if let v = value("--limit-mb") { app.sizeLimitMB = Int(v) }
        if a.contains("--auto-file") { app.listenOutput = .file; app.autoListen = true }
        if a.contains("--link-test") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                try? await Task.sleep(for: .seconds(45))
                app.sourceID = "spyserver"
                try? await Task.sleep(for: .milliseconds(300))
                app.setTypedLocation(name: "Berlin", coordinate: .init(latitude: 52.52, longitude: 13.4), iso: "de")
                log("link: public network, searched Berlin: bar=\(app.station?.name ?? "-") fromHost=\(app.station?.fromSpyHost ?? false) host=\(app.selectedHost?.placeName ?? "-") linked=\(app.locationLinkedToHost)")
                let hostPlace = app.station?.name
                app.sourceID = "rtlsdr"
                try? await Task.sleep(for: .milliseconds(300))
                log("link: switched to USB: bar=\(app.station?.name ?? "none") fromHost=\(app.station?.fromSpyHost ?? false) host=\(app.selectedHost?.placeName ?? "-") linked=\(app.locationLinkedToHost)")
                app.setTypedLocation(name: "Oslo", coordinate: .init(latitude: 59.9, longitude: 10.7), iso: "no")
                log("link: USB, searched Oslo: bar=\(app.station?.name ?? "-") fromHost=\(app.station?.fromSpyHost ?? false) host=\(app.selectedHost?.placeName ?? "-") (was \(hostPlace ?? "-"))")
                app.sourceID = "spyserver"
                try? await Task.sleep(for: .milliseconds(300))
                log("link: back to public: bar=\(app.station?.name ?? "-") host=\(app.selectedHost?.placeName ?? "none")")
                app.selectHost(app.sortedHosts().first!)
                log("link: picked a host: bar=\(app.station?.name ?? "-") fromHost=\(app.station?.fromSpyHost ?? false)")
                app.sourceID = "rtlsdr"
                try? await Task.sleep(for: .milliseconds(300))
                log("link: USB again: bar=\(app.station?.name ?? "-") (your own place comes back)")
                log("link done")
            }
        }
        if let v = value("--host-region") {
            let c = v.split(separator: ",").compactMap { Double($0) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if a.contains("--host-region-pick") { app.pickingHostRegion = true }
                else { app.pickingHostRegion = true; app.pickLocation(lat: c[0], lon: c[1]) }
            }
        }
        if a.contains("--region-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(40))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                let before = (app.station, app.selectedHostID)
                // A real click through the globe view, the way a person makes one.
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let root = win.contentView,
                   let g = { () -> GlobeNSView? in
                       func find(_ v: NSView) -> GlobeNSView? { (v as? GlobeNSView) ?? v.subviews.lazy.compactMap(find).first }
                       return find(root)
                   }() {
                    app.pickingHostRegion = true
                    try? await Task.sleep(for: .milliseconds(300))
                    let w = g.convert(CGPoint(x: g.bounds.midX, y: g.bounds.midY), to: nil)
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let e = NSEvent.mouseEvent(with: t, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        if t == .leftMouseDown { g.mouseDown(with: e) } else { g.mouseUp(with: e) }
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    log("globe click: region=\(app.hostRegion?.name ?? "none") picking=\(app.pickingHostRegion) locked=\(app.locked?.name ?? "none")")
                }
                for id in ["spyserver", "websdr"] {
                    app.sourceID = id
                    for (name, lat, lon) in [("Germany", 50.0, 10.0), ("Texas", 31.0, -99.0), ("Kenya", -1.0, 37.0), ("mid-Pacific", -30.0, -140.0)] {
                        app.pickingHostRegion = true
                        app.pickLocation(lat: lat, lon: lon)
                        guard let region = app.hostRegion else { log("no region"); continue }
                        let found = app.hostsAround(region)
                        let st = found.hosts.map(app.status(of:))
                        log("\(id) \(name): named \"\(region.name)\" radius=\(found.radiusKm.map { "\(Int($0))" } ?? "closest") hosts=\(found.hosts.count) live=\(st.filter { $0 != .dead }.count) ordered=\(st == st.sorted()) first=\(found.hosts.prefix(3).map(\.shortName))")
                    }
                    let list = app.sortedHosts()
                    log("\(id): measured \(list.filter { app.hostLinks[$0.id] != nil }.count) of \(list.count), with a state \(list.filter { !$0.state.isEmpty }.count)")
                }
                log("address unchanged: \(before.0 == app.station), picking off: \(!app.pickingHostRegion)")
                log("region done")
            }
        }
        if let v = value("--filter-comm"), let k = CommunicationKind.allCases.first(where: { "\($0)" == v }) { app.satelliteFilter.communication = k }
        if a.contains("--comm-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(14))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                for k in CommunicationKind.allCases {
                    let strict = store.satellites.filter { CommunicationKind.of(norad: $0.norad, uplinks: UplinkPolicy.listedUplinks(for: $0)).contains(k) }.count
                    log("\(k.rawValue): transmit rules alone would give \(strict)")
                }
                log("registry entries: \(store.satellites.filter { $0.registry != nil }.count) of \(store.satellites.count); unclassified \(store.satellites.filter { $0.category == .unknown }.count)")
                if let s = store.satellite(norad: 101093) { log("NIS-PQ category \(s.category.rawValue), registry \(s.registry != nil), owner \(s.ownerCode)") }
                log("frequency listed: \(store.satellites.filter(\.hasPublicFrequency).count), linked by number or name: \(store.satellites.filter { $0.satnogsNumber != nil }.count)")
                if let s = store.satellite(norad: 101093) { log("\(s.name): \(s.transmitters.map { "\($0.downlinkHz) \($0.mode)" }), listed \(s.hasPublicFrequency), tune \(s.primaryDownlink?.downlinkHz ?? 0), satnogs \(s.satnogsNorad)") }
                log("duplicates under temporary numbers: \(store.satellites.filter { $0.fromSatNOGS }.count) from SatNOGS, ids \(Set(store.satellites.map(\.norad)).count)/\(store.satellites.count)")
                for k in CommunicationKind.allCases {
                    app.satelliteFilter = SatelliteFilter(communication: k)
                    try? await Task.sleep(for: .milliseconds(200))
                    let names = store.satellites.filter { !$0.filteredOut }.map(\.name)
                    log("\(k.rawValue): menu \(store.communicationCounts[k] ?? 0), shown \(store.shownCount(of: nil)): \(names.prefix(9))")
                }
                app.satelliteFilter = SatelliteFilter()
                log("comm done")
            }
        }
        if let v = value("--audio-check"), let port = Int(v) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                guard let sat = store.satellites.first(where: { $0.norad == 25544 }), let source = SDRCatalog.source("rtltcp"),
                      let pipeline = app.runner.catalog.pipeline("analog_demod") else { log("audio: missing parts"); return }
                log("audio: analog has sound \(pipeline.hasAudio), lrpt-style \(app.runner.catalog.pipelines.first { $0.id == "meteor_m2-x_lrpt" }?.hasAudio ?? false)")
                app.lock(sat)
                final class Tally: @unchecked Sendable { var at1k = 0.0, other = 0.0, samples = 0, rate = 0.0 }
                let tally = Tally()
                app.audioMonitor.testSink = { s, rate in
                    DispatchQueue.main.async {
                        func power(_ f: Double) -> Double {
                            var re = 0.0, im = 0.0
                            for (i, x) in s.enumerated() { let w = 2 * Double.pi * f * Double(i) / rate; re += Double(x) * cos(w); im += Double(x) * sin(w) }
                            return (re * re + im * im).squareRoot() / Double(max(s.count, 1))
                        }
                        tally.at1k += power(1000); tally.other += power(700); tally.samples += s.count; tally.rate = rate
                    }
                }
                app.runner.start(CaptureRequest(mode: .listen, source: source, address: "127.0.0.1", port: port, pipelineID: "analog_demod",
                                            frequencyHz: 145_800_000, sampleRate: 240_000, gain: nil, bias: false, bitDepth: nil,
                                            basebandFormat: "cu8", dcBlock: false, iqSwap: false, finishProcessing: false,
                                            outputDir: FileManager.default.temporaryDirectory, label: "audio-check",
                                            extraArgs: ["--modulation_type", "NFM", "--satellite_norad", "25544", "--satellite_frequency", "145800000", "--enable_doppler", "false"],
                                            norad: 25544))
                app.speakerOn = false
                try? await Task.sleep(for: .seconds(8))
                log("muted: \(tally.samples) samples reached the output")
                app.speakerOn = true
                try? await Task.sleep(for: .seconds(8))
                let heard = tally.samples
                log("playing: \(heard) samples at \(Int(tally.rate)) Hz, strength at 1 kHz \(String(format: "%.4f", tally.at1k)) vs 700 Hz \(String(format: "%.4f", tally.other))")
                app.speakerOn = false
                try? await Task.sleep(for: .seconds(2))
                let afterMute = tally.samples
                try? await Task.sleep(for: .seconds(3))
                log("muted again: \(tally.samples - afterMute) more samples")
                app.speakerOn = true
                try? await Task.sleep(for: .seconds(3))
                log("unmuted: \(tally.samples - afterMute) more samples")
                app.speakerOn = false
                app.runner.stop()
                log("audio done")
            }
        }
        if a.contains("--transmit-page") { app.panelMode = .transmit }
        if let v = value("--filter-media"), let k = MediaKind.allCases.first(where: { $0.rawValue == v }) { app.satelliteFilter.media = k }
        if a.contains("--media-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(18))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                for k in MediaKind.allCases {
                    app.satelliteFilter = SatelliteFilter(media: k)
                    try? await Task.sleep(for: .milliseconds(200))
                    let shown = store.satellites.filter { !$0.filteredOut }
                    let noFrequency = shown.filter { s in !s.media.contains { $0.kind == k } }.map(\.name)
                    log("\(k.rawValue): menu \(store.mediaCounts[k] ?? 0), shown \(store.shownCount(of: nil)): \(shown.prefix(10).map(\.name)); AMSAT only: \(noFrequency.prefix(8))")
                }
                app.satelliteFilter = SatelliteFilter()
                for n in [25544, 60239, 68446] {
                    guard let sat = store.satellites.first(where: { $0.norad == n }) else { log("\(n) not in the catalogue"); continue }
                    app.lock(sat)
                    log("\(sat.name) default \(app.frequency.map { formatHz($0) } ?? "-") pipeline \(app.pipeline?.id ?? "none") rate \(formatHz(app.sampleRate)) media \(sat.media.map { "\($0.title) \(formatHz($0.hz))" })")
                    for m in sat.media {
                        app.tuneMedia(m)
                        log("  tuned \(m.title): \(app.frequency.map { formatHz($0) } ?? "-") active \(app.activeMedia?.title ?? "none") pipeline \(app.pipeline?.id ?? "none") output \(app.listenOutput.rawValue) rate \(formatHz(app.sampleRate))")
                    }
                    app.retune()
                    log("  retuned: \(app.frequency.map { formatHz($0) } ?? "-") active \(app.activeMedia?.title ?? "none") pipeline \(app.pipeline?.id ?? "none")")
                }
                app.listenOutput = .decode
                app.unlock()
                log("media done")
            }
        }
        if let v = value("--sstv-check"), let port = Int(v) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                guard let source = SDRCatalog.source("rtltcp") else { return }
                let seconds = Double(value("--sstv-seconds") ?? "50") ?? 50
                app.runner.start(CaptureRequest(mode: .listen, source: source, address: "127.0.0.1", port: port, pipelineID: "analog_demod",
                                                frequencyHz: 145_800_000, sampleRate: 240_000, gain: nil, bias: false, bitDepth: nil,
                                                basebandFormat: "cu8", dcBlock: false, iqSwap: false, finishProcessing: false,
                                                outputDir: FileManager.default.temporaryDirectory, label: "sstv-check",
                                                extraArgs: ["--modulation_type", "NFM", "--satellite_norad", "25544", "--satellite_frequency", "145800000", "--enable_doppler", "false"] + (value("--analog-bw").map { ["--bandwidth", $0] } ?? []),
                                                norad: 25544))
                var was = ""
                // Brings the Capture panel into view, for checking it in a screenshot.
                if let v = value("--scroll-sidebar"), let y = Double(v), let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 400 })?.contentView {
                    func scrollers(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollers) }
                    if let sidebar = scrollers(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }), let doc = sidebar.documentView {
                        doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? y : doc.frame.height - y - sidebar.frame.height))
                    }
                }
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    try? await Task.sleep(for: .seconds(5))
                    let now = "\(app.sstv.liveTitle ?? "-") row \(app.sstv.liveRows)/\(app.sstv.liveHeight), finished \(app.sstv.finished.map(\.title))"
                    if now != was { log("sstv: \(now)"); was = now }
                }
                log("format: listed \(app.listedFormat?.rawValue ?? "none"), sounds like \(app.formats.sound?.rawValue ?? "nothing")")
                log("sstv saved: \(app.sstv.finished.map(\.file.path))")
                for p in app.packets.packets.reversed() {
                    log("packet: \(p.frame.source)>\(p.frame.destination) via \(p.frame.path): \(p.report?.kind.rawValue ?? "raw") \(p.report?.latitude ?? 0),\(p.report?.longitude ?? 0) \(p.report?.addressee ?? "") \(p.report?.text ?? p.frame.infoText)")
                }
                log("packets total: \(app.packets.packets.count)")
                app.runner.stop()
                log("sstv done")
            }
        }
        if a.contains("--rotator-check") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                if let v = value("--rotator-source") { app.sourceID = v }
                // Against a dummy rotctld started by hand, so nothing real can move.
                rotator.connection = .network
                rotator.address = "127.0.0.1"
                rotator.port = Int(value("--rotator-port") ?? "") ?? 14533
                rotator.connect()
                try? await Task.sleep(for: .seconds(2))
                log("rotator: \(rotator.status) az \(rotator.actualAz ?? -1) el \(rotator.actualEl ?? -1)")
                // Whichever satellite is well up from here right now.
                let st = app.ownStation
                var chosen: Satellite?
                let jd = Astro.julianDate()
                for sat in store.satellites where sat.orbit == .leo {
                    guard let st, let s = sat.clone()?.state(jd: jd) else { continue }
                    let look = Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon)
                    if look.el > 25, look.el < 70 { chosen = sat; break }
                }
                guard let chosen else { log("rotator: nothing overhead"); return }
                app.lock(chosen)
                rotator.updateSeconds = 1
                rotator.deadband = 1
                rotator.setTracking(true)
                // Brings the Capture panel into view, for checking it in a screenshot.
                if let v = value("--scroll-sidebar"), let y = Double(v), let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 400 })?.contentView {
                    func scrollers(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollers) }
                    if let sidebar = scrollers(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }), let doc = sidebar.documentView {
                        doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? y : doc.frame.height - y - sidebar.frame.height))
                    }
                }
                // Draws the panel off-screen, as the popup closes when another app is in front.
                try? await Task.sleep(for: .seconds(10))
                if let path = value("--rotator-png") {
                    let panel = ImageRenderer(content: RotatorDial(rotator: rotator).padding(12).frame(width: 320).environment(\.colorScheme, .dark).background(Color(white: 0.13)))
                    panel.scale = 2
                    if let image = panel.cgImage { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                    let settings = ImageRenderer(content: RotatorSettings(rotator: rotator).environment(\.colorScheme, .dark).background(Color(white: 0.13)))
                    settings.scale = 2
                    if let image = settings.cgImage { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".settings.png")) }
                }
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(3))
                    log(String(format: "%@ %@: antenna az %.1f el %.1f, satellite az %.1f el %.1f, %@", chosen.name, rotator.isTracking ? "tracking" : "off", rotator.actualAz ?? -1, rotator.actualEl ?? -1, rotator.targetAz ?? -1, rotator.targetEl ?? -1, "\(rotator.activity)"))
                }
                // A public source has no antenna of yours to turn, so this has to stop it.
                app.sourceID = "spyserver"
                try? await Task.sleep(for: .seconds(2))
                log("switched to public: supported \(app.supportsRotator), tracking \(rotator.isTracking)")
                rotator.setTracking(true)
                log("asked to track there: \(rotator.isTracking)")
                app.sourceID = value("--rotator-source") ?? "spyserver"
                rotator.park()
                try? await Task.sleep(for: .seconds(4))
                log(String(format: "parking: antenna az %.1f el %.1f, tracking %@", rotator.actualAz ?? -1, rotator.actualEl ?? -1, rotator.isTracking ? "yes" : "no"))
                rotator.stop()
                app.unlock()
                log("rotator done")
            }
        }
        if a.contains("--update-check") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                for i in DataUpdates.items { log("\(i.title): \(DataUpdates.age(of: i.file).map(DataUpdates.words(age:)) ?? "none")") }
                let locked = store.satellite(norad: 25544)
                if let locked { app.lock(locked) }
                let before = app.locked.map { ObjectIdentifier($0) }
                let count = store.satellites.count
                let ok = await store.reload(force: true)
                try? await Task.sleep(for: .seconds(3))
                log("reload ok=\(ok) sats \(count)->\(store.satellites.count) version \(store.catalogVersion), same object=\(before == app.locked.map { ObjectIdentifier($0) }) still locked=\(app.locked?.name ?? "none") radio entries=\(app.locked?.transmitters.count ?? 0) comms=\(store.communicationCounts.count)")
                log("update done")
            }
        }
        if a.contains("--menu-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                for top in NSApp.mainMenu?.items ?? [] {
                    let items: [String] = top.submenu?.items.filter { !$0.isSeparatorItem }.map { (i: NSMenuItem) -> String in
                        let key = i.keyEquivalent.isEmpty ? "" : " [\(i.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\(i.keyEquivalent)]"
                        return i.title + key + (i.isEnabled ? "" : " (off)")
                    } ?? []
                    FileHandle.standardError.write(Data("MENU \(top.title): \(items.joined(separator: " | "))\n".utf8))
                }
                FileHandle.standardError.write(Data("menu done\n".utf8))
            }
        }
        if let v = value("--space-object"), let o = SpaceCatalog.all.first(where: { $0.name.lowercased().contains(v.replacingOccurrences(of: "_", with: " ").lowercased()) }) {
            app.openSpaceObject(o, store: store)
        }
        if let v = value("--scroll-after"), let y = Double(v) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(18))
                guard let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 300 })?.contentView else { return }
                func scrollers(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollers) }
                guard let sidebar = scrollers(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                      let doc = sidebar.documentView else { return }
                doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? y : doc.frame.height - y - sidebar.frame.height))
            }
        }
        // Reports how it went and never the place, which is nobody else's business.
        if a.contains("--find-location") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                try? await Task.sleep(for: .seconds(4))
                let before = app.station
                let saved = UserDefaults.standard.data(forKey: "typedStation")
                app.findMyLocation(skipWifi: a.contains("--skip-wifi"))
                while app.findingMyLocation { try? await Task.sleep(for: .milliseconds(200)) }
                UserDefaults.standard.set(saved, forKey: "typedStation")
                log("find-location: moved \(app.station != before), named \(!(app.station?.name.isEmpty ?? true)), flag \(!(app.station?.iso.isEmpty ?? true)), note: \(app.locationNote?.text ?? "none")")
            }
        }
        if let text = value("--location-note") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                app.showLocationNote(text == "wifi" ? .wifi(accuracy: 65) : text == "fail" ? .notFound : .internetAddress(wifi: .notAllowed))
            }
        }
        if a.contains("--saved-open") {
            app.showPinnedForTest([
                SavedLocation(name: "GPS 41.27484, 1.98769", latitude: 41.27484, longitude: 1.98769, iso: "es", saved: Date()),
                SavedLocation(name: "GPS 51.47690, -0.00050", latitude: 51.4769, longitude: -0.0005, iso: "gb", saved: Date().addingTimeInterval(-86400)),
            ])
        }
        if a.contains("--hardware-report") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                try? await Task.sleep(for: .seconds(Double(value("--hardware-wait") ?? "20") ?? 20))
                log("hardware: selected \(app.sourceID), attached \(app.attachedHardware.map(\.title)), engine \(app.runner.detectedDevices.map(\.type))")
                for s in SourceMenu.sections(attached: app.attachedHardware) { log("menu \(s.title): \(s.entries.map(\.title))") }
            }
        }
        if a.contains("--gps-popup") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if let v = value("--gps-source") {
                    app.sourceID = v
                    // Changing source clears the address once it's settled.
                    try? await Task.sleep(for: .seconds(1))
                }
                if let v = value("--gps-address") { app.address = v }
                app.gpsOffer = GPSOffer(reason: "No Wi-Fi or internet", canUseInternet: false)
            }
        }
        if a.contains("--decoder-report") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                let outcome = await SatNOGSDecoderFiles.update()
                log("update: \(outcome.words), commit \(SatNOGSDecoderFiles.installedCommit ?? "none"), installed \(SatNOGSDecoderFiles.installedCount)")
                for n in (value("--decoder-report") ?? "").split(separator: ",").compactMap({ Int($0) }) {
                    let formats = await SatNOGSDecoderLibrary.shared.usableFormats(norad: n)
                    let telemetry = SatNOGSTelemetry()
                    await telemetry.load(norad: n)
                    guard case .loaded(let frames) = telemetry.state else { log("\(n) \(formats): no frames (\(telemetry.state))"); continue }
                    var read = 0
                    var sample: DecodedTelemetry?
                    for f in frames {
                        if let d = await SatNOGSDecoderLibrary.shared.decode(f.bytes, norad: n) { read += 1; sample = sample ?? d }
                    }
                    if read < frames.count / 2, let f = frames.first { log("first frame \(f.frame.prefix(120)) len \(f.bytes.count)") }
                    log("\(n) \(formats): read \(read)/\(frames.count) frames; \(sample?.format ?? "-"), \(sample?.values.count ?? 0) values: \(sample?.values.prefix(8).map { "\($0.name)=\($0.value)" } ?? [])")
                    log("t=\(Int(Date().timeIntervalSince1970))")
                    try? await Task.sleep(for: .seconds(3))
                }
                log("decoder report done")
            }
        }
        if a.contains("--registry-report") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                try? await Task.sleep(for: .seconds(Double(value("--registry-wait") ?? "25") ?? 25))
                let all = store.satellites
                let n = Double(all.count)
                func pct(_ c: Int) -> String { "\(c) (\(Int(Double(c) / n * 100))%)" }
                log("catalogue \(all.count), spacecraft \(all.filter { $0.orbit == .spacecraft }.count)")
                let jd = Astro.julianDate()
                let noPosition = all.filter { $0.clone()?.state(jd: jd) == nil }
                log("no current position: \(noPosition.count): \(noPosition.prefix(12).map(\.name))")
                let extras = all.filter(\.fromSatNOGS)
                log("added from SatNOGS: \(extras.count): \(extras.prefix(14).map(\.name)), with frequency \(extras.filter { !$0.transmitters.isEmpty }.count), with registry \(extras.filter { $0.registry != nil }.count)")
                log("estimated (decaying): \(all.filter { $0.clone()?.isDecayingNow == true }.map(\.name))")
                if let swift = store.satellite(norad: 28485) { log("Swift decaying=\(swift.clone()?.isDecayingNow ?? false) \(swift.clone()?.state(jd: jd).map { String(format: "%.0f km from Earth centre", simd_length($0.r)) } ?? "none")") }
                for q in ["NAPA-1", "IO-117", "SpIRIT", "LEOPARD", "ORARI", "AISAT"] { log("search \(q): \(store.search(q, limit: 2).map { "\($0.name)(\($0.norad)) \($0.fromSatNOGS ? "added" : "listed")" })") }
                // The new parser against the same satellite through CelesTrak's numbers.
                log("by class: \(Dictionary(grouping: all, by: { $0.orbit.rawValue }).mapValues(\.count)), shown \(store.shownCount(of: nil))")
                log("with a listed frequency: \(pct(all.filter { $0.transmitters.contains { $0.downlinkHz > 0 } }.count)), or a decoder too: \(pct(all.filter(\.hasPublicFrequency).count))")
                log("not Starlink, with frequency: \(all.filter { !$0.name.hasPrefix("STARLINK") && ($0.hasPublicFrequency) }.count) of \(all.filter { !$0.name.hasPrefix("STARLINK") }.count)")
                let encryption = Dictionary(grouping: all, by: { $0.encryption.state.rawValue }).mapValues(\.count)
                log("encryption: \(encryption)")
                log("registry: \(pct(all.filter { $0.registry != nil }.count)), with builder \(pct(all.filter { !($0.registry?.builder ?? "").isEmpty }.count)), mass \(pct(all.filter { $0.registry?.massKg != nil }.count)), bus \(pct(all.filter { !($0.registry?.bus ?? "").isEmpty }.count))")
                for q in ["25544", "2554", "1998-067A", "98067A", "1998067", "2021-130A", "50463", "webb", "hubble", "20580"] {
                    log("search \(q): \(store.search(q, limit: 3).map { "\($0.name) \($0.norad) \($0.objectID)" })")
                }
                for (name, norad) in [("ISS", 25544), ("JWST", 50463), ("Hubble", 20580), ("Voyager 1", 10321), ("LRO", 35315)] {
                    guard let s = store.satellite(norad: norad) else { log("\(name): not in store"); continue }
                    let r = s.registry
                    log("\(name): orbit \(s.orbit.rawValue) desig \(r?.designator ?? "-") op [\(r?.operatorName ?? "-")] built [\(r?.builder ?? "-")] mass \(r?.massKg ?? -1) bus [\(r?.bus ?? "-")] freqs \(s.transmitters.count) enc \(s.encryption.state.rawValue) position \(s.state(jd: Astro.julianDate()).map { String(format: "%.0f km", simd_length($0.r)) } ?? "none") est=\(s.ephemeris?.isEstimated(Astro.julianDate()) ?? false)")
                }
                // Pointing, against JPL's own answer from the same place.
                if let st = app.ownStation, let jwst = store.satellite(norad: 50463), let s = jwst.state(jd: Astro.julianDate()) {
                    let look = Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(Astro.julianDate())), latDeg: st.lat, lonDeg: st.lon)
                    log(String(format: "JWST from %.3f,%.3f: az %.2f el %.2f", st.lat, st.lon, look.az, look.el))
                }
                log("registry done")
            }
        }
        if a.contains("--space-report") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                let jd = Astro.julianDate()
                // Planet maths against JPL's own numbers.
                for (planet, id) in [("Earth", 399), ("Mars", 499), ("Jupiter", 599), ("Neptune", 899)] {
                    guard let p = Planet.all.first(where: { $0.name == planet }), let track = await Horizons.track(object: id, centre: 10), let real = track.at(jd) else { log("\(planet): no answer"); continue }
                    let mine = p.position(jd: jd), theirs = real.position / Horizons.kmPerAU
                    let angle = acos(min(1, simd_dot(simd_normalize(mine), simd_normalize(theirs)))) * 180 / .pi
                    log(String(format: "%@: mine %.3f AU, JPL %.3f AU, %.2f° apart", planet, simd_length(mine), simd_length(theirs), angle))
                }
                for name in ["James Webb Space Telescope", "Voyager 1", "Lunar Reconnaissance Orbiter", "Mars Reconnaissance Orbiter"] {
                    guard let o = SpaceCatalog.all.first(where: { $0.name == name }), let id = o.horizons else { continue }
                    let sun = await Horizons.track(object: id, centre: 10), earth = await Horizons.track(object: id, centre: 399)
                    log("\(name): from Earth \(earth?.at(jd).map { SpaceWords.distance(simd_length($0.position)) } ?? "none"), from Sun \(sun?.at(jd).map { SpaceWords.distance(simd_length($0.position)) } ?? "none"), points \(sun?.points.count ?? 0)")
                }
                if let lro = await Horizons.track(object: -85, centre: 301)?.at(jd) { log("LRO above the Moon: \(Int(simd_length(lro.position) - 1737)) km at \(String(format: "%.2f", simd_length(lro.velocity))) km/s") }
                let hits = SpaceCatalog.all.filter { $0.norad != nil }.map { "\($0.name)=\(store.satellite(norad: $0.norad!)?.name ?? "MISSING")" }
                log("catalogue: \(hits)")
                log("space done")
            }
        }
        if a.contains("--telemetry-report") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                log("key saved: \(SatNOGSKey.load() != nil)")
                for n in [43017, 25544, 50463, 20580] {
                    let t = SatNOGSTelemetry()
                    await t.load(norad: n)
                    if case .loaded(let frames) = t.state {
                        log("\(store.satellite(norad: n)?.name ?? "?"): \(frames.count) frames, latest \(frames.first?.timestamp ?? "none") by \(frames.first?.observer ?? "-"): \(frames.first.map { String($0.hex.prefix(32)) } ?? "")")
                    } else { log("\(n): \(t.state)") }
                }
                for q in ["AO-91", "FOX-1B", "SO-50", "hubble", "RS-44"] {
                    log("search \(q): \(store.search(q, limit: 3).map(\.name))")
                }
                log("telemetry done")
            }
        }
        if a.contains("--receiver-report") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                try? await Task.sleep(for: .seconds(8))
                let original = app.sourceID
                app.satelliteFilter = SatelliteFilter(withinReceiver: true)
                for id in ["rtlsdr", "airspyhf", "hackrf", "plutosdr", "net_source", "spyserver", "websdr"] {
                    app.sourceID = id
                    store.setReceiverRanges(app.receiverRanges)
                    store.applyFilter(app.satelliteFilter)
                    let shown = store.satellites.filter { !$0.filteredOut }
                    let has = { (n: Int) in shown.contains { $0.norad == n } ? "yes" : "no" }
                    log("\(id): \(app.receiverRangeText) -> \(store.shownCount(of: nil)) shown, ISS \(has(25544)) Starlink \(has(44713)) GPS \(shown.contains { $0.name.hasPrefix("NAVSTAR") } ? "yes" : "no") NOAA 19 \(has(33591)) QO-100 \(has(43700))")
                }
                if let h = app.hosts.first(where: { $0.network == .spyServer && $0.maxHz < 400e6 }) {
                    app.sourceID = "spyserver"
                    app.selectHost(h)
                    store.setReceiverRanges(app.receiverRanges)
                    store.applyFilter(app.satelliteFilter)
                    log("host chosen: \(app.receiverRangeText) -> \(store.shownCount(of: nil)) shown")
                }
                app.sourceID = original
                app.satelliteFilter = SatelliteFilter()
                log("receiver done")
            }
        }
        if a.contains("--pin-check") {
            Task { @MainActor in
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                try? await Task.sleep(for: .seconds(24))
                let id = app.sourceID
                app.sourceID = "spyserver"
                log("before: selected \(app.selectedHost?.shortName ?? "none"), pinned \(app.pinnedHost?.shortName ?? "none"), list \(app.sortedHosts().count)")
                guard let h = app.sortedHosts().first(where: { app.hostHealth[$0.id] == .answering && !$0.isFull }) else { log("no answering host"); return }
                app.selectHost(h)
                log("just chosen: connection \(String(describing: app.connection)), pinned \(app.pinnedHost?.shortName ?? "none")")
                try? await Task.sleep(for: .seconds(6))
                log("after connecting: connection \(String(describing: app.connection)), pinned \(app.pinnedHost?.shortName ?? "none"), station \(app.station?.name ?? "none") fromHost \(app.station?.fromSpyHost ?? false)")
                try? await Task.sleep(for: .seconds(10))
                app.disconnectHost()
                log("disconnected: selected \(app.selectedHost?.shortName ?? "none"), pinned \(app.pinnedHost?.shortName ?? "none"), connection \(String(describing: app.connection)), station \(app.station?.name ?? "none")")
                app.setTypedLocation(name: "Strasbourg", coordinate: .init(latitude: 48.58, longitude: 7.75), iso: "fr")
                log("address pick: selected \(app.selectedHost?.shortName ?? "none"), region \(app.hostRegion?.name ?? "none"), station \(app.station?.name ?? "none"), first \(app.hostRegion.map { app.hostsAround($0).hosts.prefix(2).map(\.shortName) } ?? [])")
                app.clearHostRegion()
                app.sourceID = id
                log("pin done")
            }
        }
        if let v = value("--source-only") { app.sourceID = v }
        if a.contains("--amsat-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(14))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                let status = AMSATStatus()
                for n in [27607, 43017, 44909, 25544, 7530, 43700, 24278, 33591] {
                    guard let sat = store.satellites.first(where: { $0.norad == n }) else { log("\(n): not in the catalogue"); continue }
                    let wait = await status.refresh(name: sat.name, norad: sat.norad)
                    log("\(sat.name): failed=\(status.failed) next=\(Int(wait))s modes=\(status.modes.map { "\($0.display) \($0.latestReport ?? "none") \($0.counts)" })")
                    log("  recent: \(status.recent.prefix(3).map { "\($0.callsign) \($0.grid_square ?? "-") \($0.report)" })")
                }
                log("amsat done")
            }
        }
        if a.contains("--satellite-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(35))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                // The address bar's click, on a public network: nearest by coordinates, across borders.
                app.setTypedLocation(name: "Strasbourg", coordinate: .init(latitude: 48.58, longitude: 7.75), iso: "fr")
                let place = app.hostRegion
                let km = { (h: SpyHost) in Int(Astro.distanceKm(lat1: 48.58, lon1: 7.75, lat2: h.lat, lon2: h.lon)) }
                let near = place.map { app.hostsAround($0).hosts } ?? []
                log("address pick: region=\(place?.name ?? "none") selected=\(app.selectedHost.map { "\($0.shortName) \(km($0)) km" } ?? "none")")
                log("  nearest: \(near.prefix(6).map { "\($0.shortName) \(km($0)) km" })")
                app.clearHostRegion()
                app.hostsForSatellite = true
                log("waiting, nothing locked: \(app.hostsHearingLocked().count) hosts, mode on=\(app.hostsForSatellite)")
                guard let sat = store.satellites.first(where: { $0.norad == Int(value("--satellite-report-norad") ?? "25544") }) else { return }
                for id in ["spyserver", "websdr"] {
                    app.sourceID = id
                    app.hostsForSatellite = true
                    app.lock(sat)
                    try? await Task.sleep(for: .seconds(3))
                    let list = app.hostsHearingLocked()
                    let aos = list.compactMap { app.hostArrivals[$0.id]?.aos }
                    log("\(id) \(sat.name) on \(app.frequency.map { formatHz($0) } ?? "no frequency"): \(list.count) of \(app.hosts.filter { $0.network == app.hostNetwork }.count), in order=\(aos == aos.sorted())")
                    for h in list.prefix(4) { log("  \(h.shortName): \(app.hostArrivals[h.id].map { "\($0.aos.formatted(date: .omitted, time: .standard)) max \(Int($0.maxElevation))° inView=\($0.inView())" } ?? "-")") }
                    // Against the app's own second-accurate predictor.
                    var worst = 0.0, checked = 0
                    for h in list.prefix(12) {
                        guard let got = app.hostArrivals[h.id], !got.inView(), let copy = sat.clone(),
                              case .pass(let p) = AppState.predict(copy, Station(name: "", lat: h.lat, lon: h.lon, iso: h.iso)) else { continue }
                        worst = max(worst, abs(p.aos.timeIntervalSince(got.aos))); checked += 1
                    }
                    log("  compared \(checked) with the single-pass predictor, worst difference \(String(format: "%.1f", worst)) s")
                }
                app.sourceID = "spyserver"
                log("satellite done")
            }
        }
        if a.contains("--hosts-for-satellite") { app.hostsForSatellite = true }
        if a.contains("--strength-report") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(45))
                let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
                let bars = Dictionary(grouping: app.hosts) { app.hostLinks[$0.id]?.bars ?? -1 }.mapValues(\.count)
                log("strength: \(app.hosts.count) hosts, circles (-1 not measured): \(bars.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
                for h in app.hosts.shuffled().prefix(16) {
                    let l = app.hostLinks[h.id]
                    log("  \(h.shortName) | city=\(h.city) state=\(h.state) | \(l?.word ?? "-") \(l?.roundTripMs.map { "\(Int($0)) ms" } ?? "")")
                }
                log("strength done")
            }
        }
        if a.contains("--status-report") {
            Task {
                let rounds = value("--status-count").flatMap { Int($0) } ?? 14
                for k in 0..<rounds {
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write(Data("status \(k * 3 + 3)s snr=\(String(format: "%.1f", app.runner.snr ?? -1)) lock=\(app.runner.lockText ?? "-") health=\(app.runner.health.verdict.title) running=\(app.runner.isRunning) auto=\(app.autoStatus) | note=\(app.captureNote ?? "-") err=\(app.captureError ?? "-") problem=\(app.startProblem?.message ?? "-") el=\(Int(app.elevation ?? -99))\n".utf8))
                }
                FileHandle.standardError.write(Data("status done\n".utf8))
            }
        }
        if a.contains("--test-mouse") { Snapshot.testMouse(app: app) }
        if let v = value("--test-zoom") { Snapshot.testZoom(path: v, app: app) }
        if let v = value("--refused-out"), let s = store.satellite(norad: 41847) {
            for (name, view) in [("list", AnyView(RefusedUplinkList(satellite: s).frame(width: 290).padding(10))),
                                 ("why", AnyView(UplinkPolicy.refused(for: s).first.map { RefusedReasons(transmitter: $0.transmitter, reasons: $0.reasons) }))] {
                let r = ImageRenderer(content: view.environment(\.colorScheme, .dark).background(Color(white: 0.13)))
                r.scale = 2
                Snapshot.writePNG(r.cgImage, "\(v)-\(name).png")
            }
            FileHandle.standardError.write(Data("refused: \(UplinkPolicy.refused(for: s).map { "\($0.transmitter.description): \($0.reasons.map(\.reason))" })\n".utf8))
        }
        if a.contains("--test-je9pel") {
            let withCall = store.satellites.filter { $0.callsign != nil }
            let extra = store.satellites.filter { s in s.transmitters.contains { $0.description.hasPrefix("From the JE9PEL list") } }
            let unsafe = store.satellites.filter { s in s.transmitters.contains { $0.description.hasPrefix("From the JE9PEL list") && $0.uplinkLowHz != nil } }
            let msg = "je9pel: \(withCall.count) callsigns, \(store.je9pelAdded) downlinks added on \(extra.count) satellites, \(unsafe.count) with an uplink (must be 0); ISS=\(store.satellite(norad: 25544)?.callsign ?? "-"); e.g. \(extra.prefix(3).map { "\($0.name)" })\n"
            FileHandle.standardError.write(Data(msg.utf8))
            let before = store.shownCount(of: nil)
            app.satelliteFilter.onlyNorads = [25544, 43017]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                FileHandle.standardError.write(Data("group filter: \(before) shown before, \(store.shownCount(of: nil)) with a group of two\n".utf8))
                app.satelliteFilter.onlyNorads = nil
            }
        }
        if a.contains("--test-schedule") { Snapshot.testSchedule(store: store, app: app) }
        if let v = value("--labels-out") { Snapshot.testLabels(store: store, app: app, path: v) }
        if let v = value("--passes-out"), let p = Snapshot.livePlanner { Snapshot.testPasses(store: store, app: app, planner: p, path: v) }
        if a.contains("--test-marker") { Snapshot.testMarker(app: app, path: value("--marker-out") ?? "/tmp/marker") }
        if a.contains("--test-updater") { Snapshot.testUpdater(app: app) }
        if a.contains("--audit-pipelines") { Snapshot.auditPipelines(store: store, app: app) }
        if a.contains("--test-agc") { Snapshot.testAGC(store: store, app: app, results: results, path: value("--agc-out") ?? "/tmp/agc", mockPort: Int(value("--mock-port") ?? "") ?? 0) }
        if a.contains("--test-results") { Snapshot.testResults(store: store, app: app, path: value("--results-out") ?? "/tmp/results") }
        if a.contains("--test-spectrum") { Snapshot.testSpectrum(store: store, app: app, outputDir: value("--output"), path: value("--spectrum-out") ?? "/tmp/spectrum") }
        if a.contains("--test-auto") { Snapshot.testAutoListen(store: store, app: app, outputDir: value("--output")) }
        if a.contains("--test-radar") { Snapshot.testRadar(store: store, app: app, radar: radar) }
        if let q = value("--type-location") { Snapshot.testLocation(q, app: app) }
        if let path = value("--snapshot") {
            Task {
                try? await Task.sleep(for: .seconds(Double(value("--snapshot-after") ?? "6") ?? 6))
                if let v = value("--tune-hz"), let hz = Double(v) { app.frequencyOverride = hz }
                if a.contains("--toolbar-report"), let win = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) {
                    func walk(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(walk) }
                    let root = win.contentView?.superview ?? win.contentView!
                    let found = walk(root).compactMap { v -> (CGFloat, String)? in
                        let f = v.convert(v.bounds, to: nil)
                        guard f.minY > win.frame.height - 60, f.width > 8, f.width < 300 else { return nil }
                        let label = v.accessibilityLabel() ?? ""
                        let role = String(describing: type(of: v))
                        guard !label.isEmpty || v is NSSegmentedControl else { return nil }
                        return (f.minX, "\(role):\(label)")
                    }.sorted { $0.0 < $1.0 }
                    FileHandle.standardError.write(Data("toolbar: \(win.toolbar?.items.map { $0.itemIdentifier.rawValue.suffix(30) } ?? [])\nviews: \(found.prefix(14))\n".utf8))
                }
                if let m = value("--capture"), let run = CaptureMode(rawValue: m) {
                    app.startCapture(run)
                    try? await Task.sleep(for: .seconds(Double(value("--capture-for") ?? "40") ?? 40))
                    FileHandle.standardError.write(Data("capture: snr=\(app.runner.snr ?? -1) peak=\(app.runner.peakSNR ?? -1) lock=\(app.runner.lockText ?? "-") written=\(app.runner.bytesWritten ?? -1) err=\(app.captureError ?? app.runner.lastError ?? "-") dir=\(app.runner.outputDir?.path ?? "-")\n".utf8))
                    FileHandle.standardError.write(Data("freq=\(Int(app.frequency ?? 0)) pipeline=\(app.pipeline?.id ?? "-") sym=\(app.pipeline?.symbolRate ?? 0) override=\(app.pipelineOverrideID ?? "-") key=\(app.autoStatus) rate=\(Int(app.sampleRate)) depth=\(app.effectiveBitDepth) format=\(app.effectiveFormat) slow=\(app.slowHosts.mapValues { Int($0.rate) })\n".utf8))
                    FileHandle.standardError.write(Data("health: \(app.runner.health.verdict.level) | \(app.runner.health.verdict.title) | \(app.runner.health.verdict.detail) | noise=\(Int(app.runner.health.noiseSeconds))s good=\(app.runner.health.goodPercent ?? -1)% blocks=\(app.runner.health.history.count)\n".utf8))
                    for l in app.runner.log.suffix(10) { FileHandle.standardError.write(Data((l + "\n").utf8)) }
                }
                let panel = ImageRenderer(content: RadarPanel(startExpanded: true)
                    .environmentObject(store).environmentObject(app).environmentObject(radar).environmentObject(PassPlanner())
                    .environment(\.colorScheme, .dark).padding(10).background(Color(white: 0.1)))
                panel.scale = 2
                if let cg = panel.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path + "-radar.png"))
                }
                Snapshot.take(path: path, sidebar: AnyView(
                    VStack(spacing: 0) {
                        StackPanel(title: "Satellite", symbol: "cube.transparent") { SatelliteSection() }
                        StackPanel(title: "Listener", symbol: "antenna.radiowaves.left.and.right") { ListenerSection() }
                        StackPanel(title: "Capture", symbol: "waveform") { CaptureSection() }
                        StackPanel(title: "Transmit", symbol: "dot.radiowaves.up.forward") { TransmitSection() }
                    }
                    .environmentObject(store).environmentObject(app).environmentObject(app.runner).environmentObject(tx).environmentObject(rotator)
                ), renderer: app.renderer, app: app)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let hits = store.search(query, limit: 8)
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hits) { s in
                    Button { select(s) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "circle.fill").font(.system(size: 7))
                                .foregroundStyle(s.orbit.color)
                            Text(s.name).font(.system(size: 12))
                            Spacer()
                            Text(s.objectID).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                            Text(String(s.norad)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .padding(12)
        }
    }

    /// Click a type to show only that type. Click it again, or any other, to change.
    /// Every filter behind one button. It opens upward because the button sits at the bottom of the globe.
    private var filterBar: some View {
        Button { app.showFilters.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .medium))
                Text("Filters").font(.system(size: 11, weight: app.satelliteFilter.isActive ? .semibold : .regular))
                if app.satelliteFilter.activeCount > 0 {
                    Text("\(app.satelliteFilter.activeCount)")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Color.accentColor, in: Circle())
                }
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $app.showFilters, arrowEdge: .top) { filterOptions }
    }

    private var filterOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                filterMenu("Launched", selection: $app.satelliteFilter.year) {
                    Text("Any year").tag(Int?.none)
                    ForEach(store.launchYears, id: \.self) { Text(String($0)).tag(Optional($0)) }
                }
                filterMenu("Country", selection: $app.satelliteFilter.country) {
                    Text("Any country").tag(String?.none)
                    Divider()
                    ForEach(store.countries, id: \.name) { c in
                        Label {
                            Text("\(c.name) (\(c.count.formatted()))")
                        } icon: {
                            if let flag = FlagView.menuImage(c.iso) { Image(nsImage: flag) }
                        }
                        .tag(Optional(c.name))
                    }
                }
                filterMenu("Category", selection: $app.satelliteFilter.category) {
                    Text("Any").tag(SatCategory?.none)
                    Divider()
                    ForEach(SatCategory.allCases, id: \.self) { c in
                        Label("\(c.rawValue) (\((store.categoryCounts[c] ?? 0).formatted()))", systemImage: c.symbol)
                            .tag(Optional(c))
                    }
                }
                filterMenu("Communication", selection: $app.satelliteFilter.communication) {
                    Text("Any").tag(CommunicationKind?.none)
                    Divider()
                    ForEach(CommunicationKind.allCases) { k in
                        Text("\(k.rawValue) (\((store.communicationCounts[k] ?? 0).formatted()))").tag(Optional(k))
                    }
                }
                filterMenu("Images & video", selection: $app.satelliteFilter.media) {
                    Text("Any").tag(MediaKind?.none)
                    Divider()
                    ForEach(MediaKind.allCases) { k in
                        Text("\(k.rawValue) (\((store.mediaCounts[k] ?? 0).formatted()))").tag(Optional(k))
                    }
                }
                filterMenu("Encrypted", selection: $app.satelliteFilter.encryption) {
                    ForEach(TriFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                filterMenu("Frequency listed", selection: $app.satelliteFilter.frequency) {
                    ForEach(TriFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Only what my receiver can tune", isOn: $app.satelliteFilter.withinReceiver)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                Text(app.receiverRangeText).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([app.satelliteFilter.communication?.explanation, app.satelliteFilter.media?.explanation].compactMap { $0 }, id: \.self) { text in
                Text(text)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("\(store.shownCount(of: app.orbitFilter).formatted()) shown")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Clear") { app.satelliteFilter = SatelliteFilter() }
                    .controlSize(.small).disabled(!app.satelliteFilter.isActive)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func filterMenu<V: Hashable, C: View>(_ title: String, selection: Binding<V>, @ViewBuilder content: () -> C) -> some View {
        GridRow {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Picker(title, selection: selection, content: content)
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 2) {
            ForEach(OrbitClass.allCases) { o in
                let selected = app.orbitFilter == o
                Button {
                    app.orbitFilter = selected ? nil : o
                    // Far too spread out to pick by eye, so they come with a list.
                    showSpacecraftList = o == .spacecraft && !selected
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(o.color).frame(width: 7, height: 7)
                        Text(o.rawValue).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(selected ? Color.primary.opacity(0.16) : .clear, in: Capsule())
                    .opacity(app.orbitFilter == nil || selected ? 1 : 0.45)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { legendHover = o } else if legendHover == o { legendHover = nil }
                }
                .overlay(alignment: .topLeading) {
                    if legendHover == o {
                        LegendTip(text: "\(o.title): \(store.count(of: o).formatted()) satellites").offset(y: -32)
                    }
                }
                .zIndex(legendHover == o ? 1 : 0)
                .accessibilityLabel(o.title)
                .popover(isPresented: Binding(get: { o == .spacecraft && showSpacecraftList }, set: { if !$0 { showSpacecraftList = false } }), arrowEdge: .top) {
                    SpacecraftList { showSpacecraftList = false }
                }
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}

/// `--snapshot <path>` (in VESSEL_TEST) writes the globe, the sidebar and the 3D preview to separate PNGs, since
/// each draws through a different system (Metal, SwiftUI, SceneKit). Pick results go to stderr.
@MainActor
enum Snapshot {
    /// Fetches every catalogued model through the real path, renders each, and writes one contact sheet.
    static func modelSheet(to path: String, extra: String?) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
            var choices: [ModelChoice] = []
            for rule in ModelCatalog.rules where !choices.contains(where: { $0.path == rule.choice.path }) { choices.append(rule.choice) }
            if let n = Snapshot.arguments.firstIndex(of: "--model-only") {
                choices = Array(repeating: choices.first { $0.path.contains(Snapshot.arguments[n + 1]) }!, count: 8)
            }
            for k in [SatelliteModel.Kind.station, .flatPanel, .comsat, .weather, .cubesat, .observatory, .recon, .navigation, .generic] {
                let c = ModelCatalog.choice(forName: "\u{0}", kind: k)
                if !choices.contains(where: { $0.path == c.path }) { choices.append(c) }
            }
            if let d = extra, let files = try? FileManager.default.contentsOfDirectory(atPath: d) {
                choices = files.filter { $0.hasSuffix(".glb") }.sorted().map { ModelChoice(path: "\(d)/\($0)", title: $0, match: .exact, local: true) }
            }
            let cell = CGSize(width: 500, height: 224)
            let cols = 4, rows = (choices.count + cols - 1) / cols
            guard let device = MTLCreateSystemDefaultDevice(),
                  let ctx = CGContext(data: nil, width: Int(cell.width) * cols, height: Int(cell.height) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows)))
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            for (i, c) in choices.enumerated() {
                let started = Date()
                let node = await SatelliteModelLoader.fetch(c)
                var faces = 0
                node?.enumerateHierarchy { n, _ in faces += n.geometry?.elements.reduce(0) { $0 + $1.primitiveCount } ?? 0 }
                log(String(format: "model %@ %@ %d triangles %.2f s", node == nil ? "FAILED" : "ok", c.title, faces, Date().timeIntervalSince(started)))
                let x = CGFloat(i % cols) * cell.width, y = CGFloat(rows - 1 - i / cols) * cell.height
                if let node {
                    let r = SCNRenderer(device: device, options: nil)
                    r.scene = SatelliteModel.scene(showing: node)
                    r.pointOfView = r.scene?.rootNode.childNode(withName: "camera", recursively: false)
                    r.scene?.rootNode.childNodes.first?.childNodes.first?.removeAllActions()
                    r.scene?.rootNode.childNodes.first?.childNodes.first?.eulerAngles.x = CGFloat(i) * 0.7
                    let image = r.snapshot(atTime: 0, with: CGSize(width: cell.width, height: cell.height), antialiasingMode: .multisampling4X)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ns
                    image.draw(in: CGRect(x: x, y: y, width: cell.width, height: cell.height))
                    (c.title as NSString).draw(at: CGPoint(x: x + 6, y: y + 6), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            write(ctx.makeImage(), path)
            log("model sheet done")
        }
    }

    /// Runs a real scan with no window, and logs what it found.
    static func scanTest(band: String, seconds: Double, prefix: String?, app: AppState, store: SatelliteStore) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
            // Choosing a source clears its address, a moment after it's chosen.
            try? await Task.sleep(for: .seconds(1))
            let arg = Snapshot.arguments
            if let i = arg.firstIndex(of: "--address") { app.address = arg[i + 1] }
            if let i = arg.firstIndex(of: "--port"), let n = Int(arg[i + 1]) { app.port = n }
            let parts = band.split(separator: "-").compactMap { Double($0) }
            guard parts.count == 2 else { log("scan: needs a band"); return }
            let b = ScanBand(name: "test", lowHz: parts[0] * 1e6, highHz: parts[1] * 1e6)
            if let prefix, Snapshot.arguments.contains("--scan-best") {
                // Waits for the checks, then takes the best pairing of working host and satellite.
                try? await Task.sleep(for: .seconds(70))
                let usable = app.hosts.filter { $0.network == .spyServer && app.hostHealth[$0.id] == .answering && !$0.isFull && $0.fullControl && $0.covers(b.lowHz) && $0.maxHz > 1_000_000 }
                var top: (SpyHost, Double)?
                for s in store.satellites where s.name.hasPrefix(prefix) {
                    if let r = ScanHosts.best(usable, satellite: s, bands: [b], minElevation: 5), r.elevation > (top?.1 ?? 0) { top = (r.host, r.elevation) }
                }
                if let top { app.selectHost(top.0); log("scan: best host \(top.0.host) \(top.0.antenna), elevation \(Int(top.1))") }
                try? await Task.sleep(for: .seconds(5))
            }
            guard let st = app.station else { log("scan: needs a location"); return }
            guard let source = app.scanSource(forceEngine: Snapshot.arguments.contains("--scan-engine")) else { log("scan: \(app.scanSourceProblem ?? "no source")"); return }
            let jd = Astro.julianDate()
            var pick = store.satellites.first { $0.name.hasPrefix(prefix ?? "\u{0}") }
            if let prefix {
                // The highest one of that name in this host's sky.
                let named = store.satellites.filter { $0.name.hasPrefix(prefix) }
                pick = named.compactMap { s -> (Satellite, Double)? in
                    guard let state = s.clone()?.state(jd: jd) else { return nil }
                    return (s, Astro.lookAngles(target: Astro.ecef(state.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon).el)
                }.max { $0.1 < $1.1 }?.0
            }
            guard let sat = pick ?? app.locked else { log("scan: no satellite"); return }
            app.lock(sat)
            let scanner = FrequencyScanner()
            scanner.start(source: source, bands: [b], satellite: sat, station: st)
            log("scan: \(sat.name) through \(app.selectedHost?.placeName ?? app.source.name)")
            let start = Date()
            var next = 15.0
            while Date().timeIntervalSince(start) < seconds {
                try? await Task.sleep(for: .seconds(1))
                if Date().timeIntervalSince(start) >= next {
                    next += 15
                    log("scan \(Int(Date().timeIntervalSince(start)))s state=\(scanner.state) sweeps=\(scanner.sweeps) el=\(Int(scanner.elevation ?? -99)) windows=\(scanner.windows.count) candidates=\(scanner.candidates.count)")
                }
            }
            for c in scanner.candidates.prefix(14) {
                log(String(format: "  %.4f MHz (last %.4f) +%.0f dB %.1f kHz x%d ", c.restHz / 1e6, c.lastHz / 1e6, c.strengthDB, c.widthHz / 1000, c.sightings) + c.verdict.title)
            }
            scanner.stop()
            log("scan done")
        }
    }

    /// Clicks the toolbar's sidebar button through the window, the way the mouse does, and reports
    /// the longest time the main thread was stuck.
    static func clickStress(count: Int, gap: Double) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) else { log("click: no window"); return }
            var worst = 0.0, clicks = 0
            var widths = Set<Int>()
            for k in 0..<count {
                let items = win.toolbar?.items ?? []
                guard let item = items.first(where: { $0.label == "Sidebar" }), let v = item.view, v.window != nil else {
                    if k == 0 { log("click: items \(items.map { "\($0.label)|\($0.view == nil)" })") }
                    try? await Task.sleep(for: .seconds(gap))
                    continue
                }
                let p = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                func ev(_ t: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseDown ? 1 : 0)!
                }
                let before = CACurrentMediaTime()
                win.sendEvent(ev(.mouseMoved))
                NSApp.postEvent(ev(.leftMouseUp), atStart: false)
                win.sendEvent(ev(.leftMouseDown))
                win.sendEvent(ev(.leftMouseUp))
                clicks += 1
                try? await Task.sleep(for: .seconds(gap))
                if let root = win.contentView, let g = views(of: GlobeNSView.self, in: root).first {
                    widths.insert(Int(g.convert(g.bounds, to: nil).width / 100))
                }
                worst = max(worst, CACurrentMediaTime() - before - gap)
                if k % 25 == 0 { log(String(format: "click %d at %.0f,%.0f worst stall %.2f s", k, p.x, p.y, worst)) }
            }
            log(String(format: "click done %d clicks, worst stall %.2f s, globe widths seen (x100 pt): ", clicks, worst) + "\(widths.sorted())")
        }
    }

    /// Read from the environment because AppKit also interprets command-line arguments.
    static var arguments: [String] {
        (ProcessInfo.processInfo.environment["VESSEL_TEST"] ?? "").split(separator: " ").map(String.init)
    }

    private static func views<T: NSView>(of type: T.Type, in v: NSView) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Sends real events through the window: hover a satellite, read its tag, then click to lock it.
    static func testMouse(app: AppState) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let root = win.contentView,
                  let g = views(of: GlobeNSView.self, in: root).first, let r = g.renderer else { return }
            let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
            guard let sat = r.pick(at: CGPoint(x: g.bounds.midX + 150, y: g.bounds.midY), radius: 100),
                  let p = r.screenPoint(norad: sat.norad) else { log("mouse test: no satellite"); return }
            let w = g.convert(p, to: nil)
            func ev(_ t: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            g.mouseMoved(with: ev(.mouseMoved))
            log("mouse test: hover target=\(sat.name) hoveredNorad=\(r.hoveredNorad ?? -1) tagHidden=\(g.hoverTag.isHidden)")
            win.sendEvent(ev(.leftMouseDown))
            win.sendEvent(ev(.leftMouseUp))
            try? await Task.sleep(for: .milliseconds(300))
            log("mouse test: locked=\(app.locked?.name ?? "none") class=\(app.locked?.orbit.rawValue ?? "-")")
        }
    }

    static func testLocation(_ q: String, app: AppState) {
        let c = LocationCompleter()
        c.update(q)
        Task {
            try? await Task.sleep(for: .seconds(3))
            let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
            log("location suggestions: \(c.results.map(\.title))")
            if let first = c.results.first, let (name, coord, iso) = await c.resolve(first) {
                app.setTypedLocation(name: name, coordinate: coord, iso: iso)
                log("location picked: \(name) \(coord.latitude),\(coord.longitude) iso=\(iso) nearest host=\(app.selectedHost?.host ?? "-") \(app.selectedHost?.countryName ?? "")")
            }
        }
    }

    /// Edge energy of a frame's central area: higher means more fine detail reaches the screen.
    nonisolated private static func sharpness(_ cg: CGImage) -> Double {
        let w = 600, h = 600
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let crop = cg.cropping(to: CGRect(x: (cg.width - w) / 2, y: (cg.height - h) / 2, width: w, height: h)),
              let data = { ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let lap = 4 * Double(p[y * w + x]) - Double(p[y * w + x - 1]) - Double(p[y * w + x + 1]) - Double(p[(y - 1) * w + x]) - Double(p[(y + 1) * w + x])
                sum += lap * lap; n += 1
            }
        }
        return sum / n
    }

    /// The same view with and without streamed imagery, at several zoom levels, over Bengaluru.
    static func testZoom(path: String, app: AppState) {
        Task {
            guard let r = app.renderer else { return }
            let log = { (s: String) in FileHandle.standardError.write(Data("zoomtest: \(s)\n".utf8)) }
            func grab(_ name: String) async -> Double {
                await withCheckedContinuation { c in
                    r.captureNext = { cg in
                        write(cg, "\(path)-\(name).png")
                        c.resume(returning: cg.map(sharpness) ?? 0)
                    }
                }
            }
            r.cancelFly(); r.lonVel = 0; r.latVel = 0
            r.lon = 77.59; r.lat = 12.97
            for d: Float in [2.2, 1.3, 1.05, 1.01, GlobeNSView.closest] {
                r.targetDistance = d; r.distance = d
                let altitude = Int((d - 1) * 6378)
                r.tilesEnabled = false
                try? await Task.sleep(for: .milliseconds(300))
                let before = await grab("off-\(altitude)km")
                r.tilesEnabled = true
                var waited = 0
                repeat {
                    try? await Task.sleep(for: .milliseconds(500)); waited += 1
                } while (r.tiles.isBusy || waited < 2) && waited < 60
                try? await Task.sleep(for: .milliseconds(300))
                let after = await grab("on-\(altitude)km")
                log(String(format: "%5d km: base %8.1f  tiles %8.1f  x%.1f  (%d tiles, deepest z%d, %.1fs)", altitude, before, after, after / max(before, 0.01), r.tilesDrawn, r.deepestTile, Double(waited) / 2))
            }
            log("downloaded \(r.tiles.downloaded), holding \(r.tiles.loadedCount)")
            // Accuracy close to the ground: a pick must return the point under the camera.
            if let spot = r.surfacePoint(at: CGPoint(x: 400, y: 400)), let back = r.screenPoint(lat: spot.lat, lon: spot.lon) {
                log("pick round trip at the closest zoom: \(back) from (400, 400)")
            }
            r.distance = 4.2; r.targetDistance = 4.2
            log("DONE")
        }
    }

    /// The engine must really load a new decoder through the override file, and an update that
    /// breaks a decoder must be visible as a lost one, which is what gets it rejected.
    static func testUpdater(app: AppState) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("updtest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            guard let exe = app.runner.executable else { log("FAIL no engine"); log("DONE"); return }
            let base = await PipelineUpdater.loadedDecoders(engine: exe, override: nil)
            expect("engine lists its decoders", base.count > 150, "\(base.count)")
            log("engine: \(exe.lastPathComponent)")

            let good = """
            { "vessel_test_new": { "name": "Test New", "live": [1, 2], "frequencies": [["Main", 137.5e6]],
              "parameters": { "samplerate": { "value": 1e6 } },
              "work": { "baseband": {}, "soft": { "module": "psk_demod", "parameters": { "constellation": "bpsk", "symbolrate": 10000, "rrc_alpha": 0.5, "pll_bw": 0.01 } } } } }
            """
            let added = await PipelineUpdater.loadedDecoders(engine: exe, override: PipelineUpdater.merge([good]))
            expect("a new decoder loads through the override file", added.contains("vessel_test_new") && base.isSubset(of: added), "\(added.count)")

            let broken = """
            { "metop_ahrpt": { "name": "Broken", "live": [1], "work": { "baseband": {}, "soft": { "module": "module_that_does_not_exist", "parameters": {} } } } }
            """
            let hurt = await PipelineUpdater.loadedDecoders(engine: exe, override: PipelineUpdater.merge([broken]))
            log("with a broken update: \(hurt.count) decoders, metop_ahrpt present=\(hurt.contains("metop_ahrpt"))")
            expect("a broken update is noticed", !hurt.contains("metop_ahrpt") || hurt != base)

            let garbage = await PipelineUpdater.loadedDecoders(engine: exe, override: "{ this is not json")
            expect("an unreadable file leaves every decoder in place", base.isSubset(of: garbage), "\(garbage.count)")
            log("DONE")
        }
    }

    /// Every rule's decoders must exist, and well-known satellites must land on the right one.
    static func auditPipelines(store: SatelliteStore, app: AppState) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("audit: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            let cat = app.runner.catalog
            let rules = PipelineRules.load()
            let missing = rules.flatMap(\.pipelines).filter { cat.pipeline($0) == nil }
            expect("every rule's decoders exist", missing.isEmpty, "\(rules.count) rules, \(cat.pipelines.count) decoders, missing \(missing)")
            let cases: [(String, String?)] = [
                ("METEOR-M2 4", "meteor_m2-x_lrpt"), ("METEOR-M2 3", "meteor_m2-x_lrpt"), ("METOP-B", "metop_ahrpt"), ("GOES 18", "goes_hrit"),
                ("HIMAWARI-9", "himawaricast"), ("GEO-KOMPSAT-2A", "gk2a_lrit"), ("ELEKTRO-L 4", "elektro_lrit"), ("FENGYUN 3C", "fengyun3_c_ahrpt"),
                ("FENGYUN 4A", "fengyun4_a_lrit"), ("METEOSAT-11 (MSG-4)", "msg_raw"), ("JASON-3", "jason3_link"), ("AQUA", "aqua_db"),
                ("TERRASAR-X", nil), ("TERRA NOVA", nil), ("COSMOS 2385", nil), ("TERRA", nil), ("LANDSAT 9", nil), ("FENGYUN 3D", nil), ("NOAA 21 (JPSS-2)", "jpss_tlm"),
            ]
            for (name, want) in cases {
                guard let s = store.satellites.first(where: { $0.name == name }) else { log("  no \(name) today"); continue }
                let t = cat.select(for: s)
                // Satellites with analog downlinks may legitimately land on the analog demodulator.
                let got = t.pipeline?.id
                expect("\(name) -> \(want ?? "no digital decoder")", got == want || (want == nil && got == "analog_demod"), "\(got ?? "none"), \(t.frequencyHz.map(formatHz) ?? "-"), \(t.reason)")
            }
            var counts: [String: Int] = [:]
            for s in store.satellites {
                let t = cat.select(for: s)
                let k = t.pipeline?.id == "analog_demod" ? "analog" : t.pipeline != nil ? "decoder" : t.frequencyHz != nil ? "save to file" : "no frequency"
                counts[k, default: 0] += 1
            }
            log("all satellites: \(counts.sorted { $0.key < $1.key })")
            log("rules saved at \(PipelineRules.savedURL.path), exists=\(FileManager.default.fileExists(atPath: PipelineRules.savedURL.path))")

            // Choosing by hand survives, and automatic comes back.
            if let s = store.satellites.first(where: { $0.name == "METOP-B" }) {
                app.lock(s)
                app.choosePipeline("metop_dump")
                let again = PipelineChoices()
                expect("hand choice saved to disk", again.manual(norad: s.norad) == "metop_dump" && app.pipeline?.id == "metop_dump")
                app.unlock(); app.lock(s)
                expect("hand choice comes back on relock", app.pipeline?.id == "metop_dump")
                app.choosePipeline(nil)
                expect("automatic restores the rule", app.pipeline?.id == "metop_ahrpt" && PipelineChoices().manual(norad: s.norad) == nil)
                app.unlock()
            }

            // Update check: wait for the one the app runs at launch.
            for _ in 0..<80 where app.runner.lastPipelineOutcome == nil { try? await Task.sleep(for: .seconds(1)) }
            if let o = app.runner.lastPipelineOutcome {
                expect("update check ran", o.checked, o.message)
                log("  updated \(o.updatedFiles), rejected \(o.rejectedFiles)")
                log("  decoders now \(app.runner.catalog.pipelines.count), override exists=\(FileManager.default.fileExists(atPath: PipelineUpdater.overrideFile.path))")
            } else { log("FAIL update check never finished") }

            // Searched location: a known place puts its hosts first.
            app.sourceID = "spyserver"
            app.setTypedLocation(name: "Oulu", coordinate: .init(latitude: 65.01, longitude: 25.47), iso: "fi")
            try? await Task.sleep(for: .seconds(1))
            let sorted = app.sortedHosts()
            let top = sorted.prefix(6).map { "\($0.iso):\($0.status(app))" }
            let alive = sorted.filter { $0.status(app) != HostStatus.dead.rawValue }
            let km = alive.map { Astro.distanceKm(lat1: app.station!.lat, lon1: app.station!.lon, lat2: $0.lat, lon2: $0.lon) }
            expect("the nearest hosts lead the list", km == km.sorted(), "\(top)")
            log("DONE")
        }
    }

    /// Measures how much of the pulse is drawn on each side of its centre, at spots across the view.
    static func testMarker(app: AppState, path: String) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("markertest: \(s)\n".utf8)) }
            guard let r = app.renderer else { return }
            try? await Task.sleep(for: .seconds(2))
            r.tilesEnabled = false
            // Over empty night-side ocean, so the surroundings don't favour any direction.
            let testLon: Float = -150
            app.station = Station(name: "Test", lat: 0, lon: Double(testLon), iso: "")
            try? await Task.sleep(for: .milliseconds(300))
            for (i, offset) in [(0, Float(0)), (1, 25), (2, 45), (3, 58), (4, 72)] {
                r.cancelFly(); r.lonVel = 0; r.latVel = 0
                r.lat = 0; r.lon = testLon + offset; r.distance = 4.2; r.targetDistance = 4.2
                try? await Task.sleep(for: .milliseconds(1700))
                guard let g = await withCheckedContinuation({ (c: CheckedContinuation<CGImage?, Never>) in r.captureNext = { c.resume(returning: $0) } }),
                      let spot = r.screenPoint(lat: 0, lon: Double(testLon)) else {
                    // Beyond the horizon the marker is meant to be hidden, so there's nothing to measure.
                    log("PASS \(Int(offset))° is beyond the horizon, where it's hidden")
                    continue
                }
                write(g, "\(path)-\(i).png")
                let scale = CGFloat(g.width) / max(CGFloat(g.width) / 2, 1)
                let cx = Int(spot.x * scale), cy = g.height - Int(spot.y * scale)
                let radius = 56
                guard let ctx = CGContext(data: nil, width: radius * 2, height: radius * 2, bitsPerComponent: 8, bytesPerRow: radius * 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let crop = g.cropping(to: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)), let raw = { ctx.draw(crop, in: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)); return ctx.data }() else {
                    log("FAIL couldn't crop at \(offset)°: spot \(spot), frame \(g.width)x\(g.height)")
                    continue
                }
                let px = raw.bindMemory(to: UInt8.self, capacity: radius * radius * 16)
                var left = 0, right = 0, top = 0, bottom = 0
                for y in 0..<(radius * 2) {
                    for x in 0..<(radius * 2) {
                        let o = (y * radius * 2 + x) * 4
                        let red = Int(px[o]), green = Int(px[o + 1]), blue = Int(px[o + 2])
                        guard red > 150, red > green + 60, red > blue + 60 else { continue }
                        if x < radius { left += 1 } else { right += 1 }
                        if y < radius { top += 1 } else { bottom += 1 }
                    }
                }
                let lr = Double(min(left, right)) / Double(max(left, right, 1)), tb = Double(min(top, bottom)) / Double(max(top, bottom, 1))
                log("\(offset == 0 ? "PASS" : (lr > 0.6 && tb > 0.6 ? "PASS" : "FAIL")) \(Int(offset))° from centre: left \(left) right \(right) top \(top) bottom \(bottom)")
            }
            log("DONE")
        }
    }

    /// AGC across every source, on the wire against a fake server, and the saved-files dropdown.
    static func testAGC(store: SatelliteStore, app: AppState, results: ResultsStore, path: String, mockPort: Int) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("agctest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            let root = URL(fileURLWithPath: path + "-sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            app.outputDir = root
            app.autoListen = false
            await wait(1)

            for s in SDRCatalog.sources {
                app.sourceID = s.id
                log("  \(s.name): \(app.agcSpec.map { "AGC \($0.args.joined(separator: " "))" } ?? "none, \(SDRCatalog.noAGCReason(s))")")
            }
            let expected: Set<String> = ["rtlsdr", "rtltcp", "airspy", "hydrasdr", "airspyhf", "sdrplay", "plutosdr", "bladerf", "aaronia"]
            expect("installed engine confirms every AGC setting", app.runner.agcConfirmed == expected, "\(app.runner.agcConfirmed.sorted())")
            app.sourceID = "rfnm"
            expect("RFNM isn't offered AGC", app.agcSpec == nil)
            app.sourceID = "spyserver"
            app.agcBinding.wrappedValue = true
            expect("SpyServer can't have AGC switched on", !app.agcActive)

            // RTL-TCP against a fake server that records exactly what it's told.
            guard let sat = store.satellite(norad: 25544) else { return }
            app.lock(sat)
            app.listenOutput = .file
            app.sourceID = "rtltcp"
            await wait(0.5) // the panel clears the address when the source changes
            app.address = "127.0.0.1"
            app.port = mockPort
            for on in [true, false] {
                app.agcBinding.wrappedValue = on
                expect("switch reads back \(on)", app.agcActive == on)
                log("MOCK-MARK agc=\(on)")
                app.startListening()
                var waited = 0.0
                while !app.runner.isStreaming, waited < 25 { await wait(0.5); waited += 0.5 }
                await wait(2.5)
                log("command: \(app.runner.log.first ?? "-")")
                let command = app.runner.log.first ?? ""
                expect("capture really ran", app.runner.isStreaming && !command.isEmpty, app.runner.lastError ?? app.captureError ?? "")
                expect(on ? "AGC flags sent" : "no AGC flags sent", command.contains("--lna_agc") == on && command.contains("--tuner_agc") == on)
                app.stopCapture()
                waited = 0
                while app.runner.isRunning, waited < 6 { await wait(0.3); waited += 0.3 }
                await wait(0.5)
            }

            // The running key follows AGC, so switching mid-capture retunes.
            app.agcBinding.wrappedValue = false

            // A capture in progress, for the toolbar and the dropdown.
            app.sourceID = "spyserver"
            await wait(9)
            if let host = app.hosts.first(where: { $0.network == .spyServer && app.hostHealth[$0.id] == .answering && !$0.isFull && $0.fullControl && $0.covers(145.8e6) }) {
                app.selectHost(host)
                await wait(4)
                app.startListening()
                var waited = 0.0
                while !app.runner.isStreaming, waited < 30 { await wait(0.5); waited += 0.5 }
                await wait(4)
                results.refresh(root: root)
                await wait(1)
                let running = results.sessions.first { $0.folder == app.runner.outputDir }
                expect("running capture is listed with its size", (running?.files.reduce(0) { $0 + $1.size } ?? 0) > 0, running?.files.map(\.name).description ?? "-")
                let list = ImageRenderer(content: SavedFilesList(close: {})
                    .environmentObject(app.runner).environmentObject(app).environmentObject(results)
                    .environment(\.colorScheme, .dark).background(Color(white: 0.14)))
                list.scale = 2
                write(list.cgImage, path + "-list.png")
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let frame = win.contentView?.superview ?? win.contentView,
                   let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    write(rep.cgImage, path + "-window.png")
                }
                app.stopCapture()
                waited = 0
                while app.runner.isRunning, waited < 6 { await wait(0.3); waited += 0.3 }
                await wait(1)
                results.refresh(root: root)
                await wait(1)
                let items = SavedFiles.recent(results.sessions)
                expect("saved file appears in the dropdown", items.contains { $0.file.kind == .baseband }, items.prefix(3).map(\.file.name).description)
                let done = ImageRenderer(content: VStack(spacing: 0) { ForEach(items.prefix(5)) { SavedFileRow(item: $0) } }
                    .frame(width: 350)
                    .environment(\.colorScheme, .dark).background(Color(white: 0.14)))
                done.scale = 2
                write(done.cgImage, path + "-done.png")
            }
            log("DONE")
        }
    }

    /// Results from known files, then from real captures in both listening modes.
    static func testResults(store: SatelliteStore, app: AppState, path: String) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("restest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            let root = URL(fileURLWithPath: path + "-sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            app.outputDir = root
            let results = ResultsStore()

            // A capture with one of everything, including a real generated picture.
            let folder = root.appendingPathComponent("FIXTURE_2026-01-02T03-04-05Z", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent("MSU-MR"), withIntermediateDirectories: true)
            let ctx = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.systemBlue.cgColor, NSColor.systemGreen.cgColor] as CFArray, locations: [0, 1])!, start: .zero, end: CGPoint(x: 800, y: 500), options: [])
            write(ctx.makeImage(), folder.appendingPathComponent("MSU-MR/msu_mr_rgb_221.png").path)
            try? "{\"satellite\":\"TEST\"}".write(to: folder.appendingPathComponent("dataset.json"), atomically: true, encoding: .utf8)
            try? "line one\nline two\n".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            try? AudioSignals.wav([Float](repeating: 0, count: 4800)).write(to: folder.appendingPathComponent("demod.wav"))
            try? Data(count: 4000).write(to: folder.appendingPathComponent("baseband.cs16"))
            try? Data().write(to: folder.appendingPathComponent("meteor.cadu"))
            try? Data(count: 400).write(to: folder.appendingPathComponent("MSU-MR/product.cbor"))
            let t0 = Date(timeIntervalSince1970: 1_767_323_045)
            SessionInfo(satellite: "METEOR-M2 4", norad: 59051, frequencyHz: 137.9e6, sampleRate: 1.5e6, pipelineName: "METEOR M2-x LRPT", decoding: true, source: "SpyServer", host: "Test, Finland", started: t0, ended: t0.addingTimeInterval(612)).write(to: folder)

            results.refresh(root: root)
            await wait(1.5)
            guard let s = results.sessions.first(where: { $0.folder.lastPathComponent.hasPrefix("FIXTURE") }) else { log("FAIL fixture not found"); log("DONE"); return }
            func kind(_ name: String) -> ResultKind? { s.files.first { $0.name == name }?.kind }
            expect("session details read back", s.title == "METEOR-M2 4" && s.info?.host == "Test, Finland" && s.ended.timeIntervalSince(s.started) == 612)
            expect("files identified", kind("msu_mr_rgb_221.png") == .image && kind("dataset.json") == .readable && kind("notes.txt") == .readable && kind("demod.wav") == .audio && kind("baseband.cs16") == .baseband && kind("meteor.cadu") == .decodedData && kind("product.cbor") == .product, "\(s.files.map { "\($0.name)=\($0.kind.rawValue)" })")
            expect("images come first", s.files.first?.kind == .image)
            expect("session.json isn't listed as a result", !s.files.contains { $0.name == SessionInfo.fileName })
            let image = s.files.first { $0.kind == .image }!
            let thumb = await ResultThumbnail.thumbnail(for: image.url)
            expect("image thumbnail generated", thumb != nil, "\(thumb?.size ?? .zero)")
            let textThumb = await ResultThumbnail.thumbnail(for: folder.appendingPathComponent("notes.txt"))
            expect("readable file thumbnail generated", textThumb != nil)

            let r = ImageRenderer(content: SessionSection(session: s) { _ in }.frame(width: 880).padding(14).environment(\.colorScheme, .dark).background(Color(white: 0.12)))
            r.scale = 2
            write(r.cgImage, path + "-screen.png")
            if let thumb, let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) { write(cg, path + "-thumb.png") }

            // Real captures, one in each mode.
            app.sourceID = "spyserver"
            await wait(9)
            let hosts = app.hosts.filter { $0.network == .spyServer && app.hostHealth[$0.id] == .answering && !$0.isFull && $0.fullControl && $0.covers(137.9e6) }
            guard let host = hosts.first, let sat = store.satellites.first(where: { $0.name.hasPrefix("METEOR-M2 4") }) else { log("FAIL no host"); log("DONE"); return }
            app.autoListen = false
            app.lock(sat)
            app.selectHost(host)
            await wait(4)
            for output in ListenOutput.allCases {
                app.listenOutput = output
                let before = Date()
                app.startListening()
                var waited = 0.0
                while !app.runner.isStreaming, waited < 45 { await wait(0.5); waited += 0.5 }
                expect("\(output.rawValue) streams", app.runner.isStreaming, String(format: "%.1fs, mode %@", waited, app.runner.mode?.rawValue ?? "-"))
                await wait(6)
                app.stopCapture()
                waited = 0
                var sawProcessing = false
                while app.runner.isRunning, waited < 40 { sawProcessing = sawProcessing || app.runner.isProcessing; await wait(0.2); waited += 0.2 }
                log(String(format: "%@ stopped in %.1fs, processing shown=%@", output.rawValue, waited, sawProcessing ? "yes" : "no"))
                results.refresh(root: root)
                await wait(1.5)
                guard let got = results.sessions.first(where: { $0.started >= before.addingTimeInterval(-1) && $0.info?.decoding == (output == .decode) }) else { log("FAIL no session for \(output.rawValue)"); continue }
                expect("\(output.rawValue) session recorded", got.info?.ended != nil && got.info?.satellite == sat.name, "\(got.outcome): \(got.files.map { "\($0.title) [\($0.name)] \($0.size)" })")
                if output == .decode {
                    expect("decoding made products", got.files.contains { $0.name == "dataset.json" } && got.files.contains { $0.kind == .decodedData })
                    expect("an empty capture says so", got.outcome.hasPrefix("Nothing decoded"), got.outcome)
                } else {
                    expect("saving wrote a raw signal only", got.files.contains { $0.kind == .baseband && $0.size > 0 } && !got.files.contains { $0.kind == .decodedData }, got.outcome)
                }
                await wait(1)
            }
            if let last = results.sessions.first {
                let shot = ImageRenderer(content: SessionSection(session: last) { _ in }.frame(width: 880).padding(14).environment(\.colorScheme, .dark).background(Color(white: 0.12)))
                shot.scale = 2
                write(shot.cgImage, path + "-real.png")
            }
            app.panelMode = .receive
            log("DONE")
        }
    }

    /// Live spectrum against FM broadcast stations, whose fixed frequencies show the axis is right:
    /// retuning upwards must move the same station down the plot by exactly that much.
    static func testSpectrum(store: SatelliteStore, app: AppState, outputDir: String?, path: String) {
        Task {
            let a2 = arguments
            let log = { (s: String) in FileHandle.standardError.write(Data("spectest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            func png(_ cg: CGImage?, _ name: String) {
                if let cg, let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: "\(path)-\(name).png")) }
            }
            if let outputDir { app.outputDir = URL(fileURLWithPath: outputDir) }
            app.autoListen = false
            app.sourceID = "spyserver"
            await wait(10)
            var hosts = app.hosts.filter { $0.network == .spyServer && app.hostHealth[$0.id] == .answering && !$0.isFull && $0.fullControl && $0.covers(98e6) && $0.maxSampleRate >= 1.5e6 }
            log("hosts covering FM broadcast: \(hosts.map(\.host))")
            if let i = a2.firstIndex(of: "--host-addr"), let chosen = app.hosts.first(where: { $0.host == a2[i + 1] }) { hosts.insert(chosen, at: 0) }
            guard let host = hosts.first, let sat = store.satellite(norad: 25544) else { log("FAIL no host"); log("DONE"); return }
            app.lock(sat)
            app.selectHost(host)
            await wait(4)
            let row = ImageRenderer(content: HostRow(host: host, selected: true, status: app.status(of: host), connection: app.connectionDisplay(for: host), detail: app.connectionDetail(for: host), link: app.hostLink)
                .frame(width: 300).environment(\.colorScheme, .dark).background(Color(white: 0.13)))
            row.scale = 2
            png(row.cgImage, "host")
            log("host \(host.placeName): \(app.connectionDetail(for: host)), link \(app.hostLink?.word ?? "-") \(app.hostLink?.roundTripMs.map { String(format: "%.0f ms", $0) } ?? "-")")
            expect("connection strength measured", app.hostLink?.roundTripMs != nil)

            app.showSpectrum = true
            /// Records briefly at one frequency and returns its averaged spectrum.
            @MainActor func measure(_ f: Double, snapshot: Bool = false) async -> [Float] {
                app.frequencyOverride = f
                app.startCapture(.record)
                var waited = 0.0
                while !app.runner.isStreaming, waited < 45 { await wait(0.5); waited += 0.5 }
                await wait(2.5) // let the receiver's gain settle
                let feed = app.runner.spectrum
                var sum = [Float](repeating: 0, count: feed.values.count), n: Float = 0
                for _ in 0..<12 {
                    if feed.values.count == sum.count, !sum.isEmpty { for k in sum.indices { sum[k] += feed.values[k] }; n += 1 }
                    await wait(0.25)
                }
                if snapshot {
                    expect("recording shows on the spectrum", feed.mode == .record && !feed.values.isEmpty, "\(feed.values.count) bins, rate \(feed.sampleRate), floor \(Int(feed.floorDB)) top \(Int(feed.topDB)) dB")
                    await wait(8) // a few seconds of waterfall
                    for (name, big) in [("small2", false), ("large2", true)] {
                        let r = ImageRenderer(content: SpectrumPanel(feed: feed, available: CGSize(width: 1120, height: 820), startExpanded: big) {}.environment(\.colorScheme, .dark).padding(10).background(Color(white: 0.1)))
                        r.scale = 2
                        png(r.cgImage, name)
                    }
                }
                app.stopCapture()
                waited = 0
                while app.runner.isRunning, waited < 6 { await wait(0.3); waited += 0.3 }
                if snapshot { expect("spectrum says stopped afterwards", app.runner.spectrum.mode == nil) }
                await wait(0.5)
                return n > 0 ? sum.map { $0 / n } : []
            }
            let rate = host.snappedRate(for: 1_000_000)
            log("sweeping FM broadcast at \(rate / 1e6) MS/s")
            var best: (hz: Double, rise: Float)?
            for f in stride(from: 88.5e6, through: 107.5e6, by: rate * 0.9) {
                let v = await measure(f)
                guard !v.isEmpty, let p = SpectrumFeed.peaks(v, frequency: f, sampleRate: rate, count: 1).first else { continue }
                let i = Int(((p - f) / rate + 0.5) * Double(v.count))
                let rise = v[i] - v.sorted()[v.count / 2]
                log(String(format: "  %.1f MHz: strongest %.3f MHz, %.0f dB above the noise", f / 1e6, p / 1e6, rise))
                if rise > (best?.rise ?? 0) { best = (p, rise) }
            }
            if let station = best {
                log(String(format: "strongest station found: %.3f MHz", station.hz / 1e6))
                let offset = rate * 0.2
                let below = await measure(station.hz - offset, snapshot: true)
                let above = await measure(station.hz + offset)
                let seenBelow = SpectrumFeed.peaks(below, frequency: station.hz - offset, sampleRate: rate, count: 1).first
                let seenAbove = SpectrumFeed.peaks(above, frequency: station.hz + offset, sampleRate: rate, count: 1).first
                log(String(format: "tuned below: %.3f MHz, tuned above: %.3f MHz", (seenBelow ?? 0) / 1e6, (seenAbove ?? 0) / 1e6))
                let binHz = rate / 1024
                expect("axis is right: a station reads the same frequency however it's tuned",
                       seenBelow != nil && seenAbove != nil && abs(seenBelow! - station.hz) < binHz * 25 && abs(seenAbove! - station.hz) < binHz * 25)
            } else {
                log("FAIL no station strong enough to check the axis")
            }

            // Listening shows too.
            app.frequencyOverride = nil
            app.autoListen = true
            log("DONE")
        }
    }

    /// Live check against the public directory: click a host, listen, retune, stop at the horizon.
    static func testAutoListen(store: SatelliteStore, app: AppState, outputDir: String?) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("autotest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            if let outputDir { app.outputDir = URL(fileURLWithPath: outputDir) }
            app.autoListen = true
            app.listenOutput = .decode

            for n in [25544, 36086, 49044, 53239, 54216, 48274] {
                if let s = store.satellite(norad: n) {
                    expect("\(s.name) has a frequency", s.primaryDownlink != nil, "\(s.primaryDownlink.map { formatHz($0.downlinkHz) } ?? "-") shared=\(s.sharedWith ?? "-")")
                }
            }
            for s in store.satellites where s.category == .station {
                log("  station \(s.name): \(s.primaryDownlink.map { formatHz($0.downlinkHz) } ?? "none") shared=\(s.sharedWith ?? "-")")
            }
            log("satellites with a frequency: \(store.satellites.filter { $0.primaryDownlink != nil }.count)")
            log("encryption: \(Dictionary(grouping: store.satellites, by: { $0.encryption.state.rawValue }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))")
            for n in ["NAVSTAR", "GALILEO", "STARLINK", "ONEWEB", "USA ", "GOES 18", "METEOSAT", "ISS (ZARYA)", "INTELSAT", "LANDSAT 9"] {
                if let s = store.satellites.first(where: { $0.name.hasPrefix(n) }) { log("  \(s.name): \(s.encryption.state.rawValue), \(s.encryption.method)") }
            }

            app.sourceID = "spyserver"
            await wait(12)
            let hosts = app.hosts.filter { $0.network == .spyServer && app.hostHealth[$0.id] == .answering && !$0.isFull && $0.fullControl }
            log("hosts answering with a free slot: \(hosts.count)")
            let jd = Astro.julianDate()
            @MainActor func candidates(_ h: SpyHost, up: Bool) -> [Satellite] {
                store.satellites.filter { s in
                    let tune = app.runner.catalog.select(for: s)
                    guard s.orbit != .geo, let f = tune.frequencyHz, let p = tune.pipeline, h.covers(f), h.maxSampleRate >= p.preferredRate,
                          let st = s.clone()?.state(jd: jd) else { return false }
                    let el = Astro.lookAngles(target: Astro.ecef(st.r, gmst: Astro.gmst(jd)), latDeg: h.lat, lonDeg: h.lon).el
                    return up ? el > 15 : el < -30
                }
            }
            guard let host = hosts.first(where: { candidates($0, up: true).count >= 2 }) else { log("FAIL no host with two satellites in view"); log("DONE"); return }
            let ups = candidates(host, up: true)
            log("host \(host.placeName) \(host.host), satellites up: \(ups.prefix(5).map(\.name))")

            if let dead = app.hosts.first(where: { $0.network == .spyServer && app.hostHealth[$0.id] == .silent }) {
                app.selectHost(dead)
                expect("dead host shows the spinner at once", app.connectionDisplay(for: dead) == .connecting)
                await wait(13)
                expect("dead host ends in a red cross", app.connectionDisplay(for: dead) == .failed, app.autoStatus)
                expect("dead host starts nothing", !app.runner.isRunning)
            }

            app.unlock()
            app.selectHost(host)
            expect("click shows the spinner at once", app.connectionDisplay(for: host) == .connecting)
            var waited = 0.0
            while app.connectionDisplay(for: host) == .connecting, waited < 8 { await wait(0.2); waited += 0.2 }
            expect("spinner turns into the tick", app.connectionDisplay(for: host) == .connected, String(format: "%.1fs", waited))
            await wait(3)
            expect("tick stays", app.connectionDisplay(for: host) == .connected)

            let first = ups[0]
            app.lock(first)
            await wait(1.5)
            log("locked \(first.name): \(app.autoStatus), \(app.frequency.map(formatHz) ?? "-"), \(app.pipeline?.id ?? "-"), rate \(app.sampleRate)")
            waited = 0
            while !app.runner.isStreaming, waited < 30 { await wait(0.5); waited += 0.5 }
            expect("listening starts automatically", app.runner.isStreaming && app.runner.mode == .listen, String(format: "%.1fs, %@", waited, app.autoStatus))
            expect("row shows the tick while streaming", app.connectionDisplay(for: host) == .connected)
            await wait(3)
            let args1 = app.runner.log.first ?? ""
            log("command: \(args1)")
            log("signal: snr=\(app.runner.snr ?? -1) lock=\(app.runner.lockText ?? "-")")
            expect("command carries this satellite's frequency", args1.contains("--frequency \(Int64(app.frequency ?? 0))"))
            expect("spy server is left to set its own gain", !args1.contains("digital_gain"))

            app.stopCapture()
            await wait(5)
            expect("manual stop isn't undone", !app.runner.isRunning, app.autoStatus)

            let current = app.frequency
            let second = ups.first { let t = app.runner.catalog.select(for: $0); return t.frequencyHz != current && t.frequencyHz.map { $0 < 500e6 } == true } ?? ups[1]
            app.lock(second)
            await wait(2)
            waited = 0
            while !app.runner.isStreaming, waited < 30 { await wait(0.5); waited += 0.5 }
            let args2 = app.runner.log.first ?? ""
            expect("changing satellite retunes", app.runner.isStreaming && args2.contains("--frequency \(Int64(app.frequency ?? 0))"), "\(second.name) \(app.frequency.map(formatHz) ?? "-") \(app.pipeline?.id ?? "-") err=\(app.runner.lastError ?? app.captureError ?? "-")")

            // Clicking another host while listening moves the listening there.
            if let other = hosts.first(where: { $0.id != host.id && $0.covers(app.frequency ?? 0) && !$0.isFull }) {
                app.selectHost(other)
                expect("click during listening shows the spinner", app.connectionDisplay(for: other) == .connecting)
                await wait(4)
                log("after clicking \(other.host): running=\(app.runner.isRunning) \(app.autoStatus)")
                app.selectHost(host)
                await wait(4)
            }

            if let below = candidates(host, up: false).first {
                app.lock(below)
                await wait(8)
                expect("below the horizon stops listening", !app.runner.isRunning, "\(below.name): \(app.autoStatus)")
            }
            app.unlock()
            await wait(6)
            expect("unlocking leaves nothing running", !app.runner.isRunning)
            log("DONE")
        }
    }

    /// Radar and address checks: real events through the window, with results compared to fresh propagation.
    static func testRadar(store: SatelliteStore, app: AppState, radar: RadarTracker) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("radartest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            let counts = OrbitClass.allCases.map { "\($0.rawValue)=\(store.count(of: $0))" }.joined(separator: " ")
            log("classes: \(counts)")
            for (name, want) in [("ISS", OrbitClass.leo), ("NAVSTAR", .meo), ("GOES 18", .geo), ("LANDSAT 9", .sso), ("MOLNIYA", .heo)] {
                if let s = store.satellites.first(where: { $0.name.hasPrefix(name) }) {
                    expect("\(s.name) is \(want.rawValue)", s.orbit == want, s.orbit.rawValue)
                } else { log("no \(name) in the catalogue") }
            }
            try? await Task.sleep(for: .seconds(1))
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let root = win.contentView,
                  let g = views(of: GlobeNSView.self, in: root).first, let r = g.renderer else { log("FAIL no globe"); return }
            let frame = g.convert(g.bounds, to: nil)
            let side = root.bounds.width - frame.width
            expect("globe view excludes the sidebar", frame.minX > 200 && abs(frame.maxX - root.bounds.width) < 1, "x \(frame.minX)...\(frame.maxX), sidebar \(side)")

            // Pick mode: a click at a known ground point returns that point, and doesn't lock anything.
            let before = app.locked?.norad
            r.lon = 30; r.lat = 20; r.targetDistance = 3; r.cancelFly()
            try? await Task.sleep(for: .milliseconds(400))
            let c = CGPoint(x: g.bounds.midX, y: g.bounds.midY)
            let spot = r.surfacePoint(at: c)
            expect("centre of the view is the point the camera faces", abs((spot?.lat ?? 99) - Double(r.lat)) < 0.5 && abs((spot?.lon ?? 999) - Double(r.lon)) < 0.5, "\(spot.map { "\($0.lat), \($0.lon)" } ?? "miss")")
            if let spot, let back = r.screenPoint(lat: spot.lat, lon: spot.lon) {
                expect("address marker lands where it was clicked", hypot(back.x - c.x, back.y - c.y) < 1.5, "\(back) vs \(c)")
            }
            app.pickingLocation = true
            try? await Task.sleep(for: .milliseconds(300))
            let w = g.convert(c, to: nil)
            func ev(_ t: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            g.mouseDown(with: ev(.leftMouseDown))
            g.mouseUp(with: ev(.leftMouseUp))
            try? await Task.sleep(for: .seconds(4))
            expect("globe click set the address", !app.pickingLocation && app.station != nil && app.locked?.norad == before, "\(app.station?.name ?? "-") iso=\(app.station?.iso ?? "-") \(app.station?.lat ?? 0), \(app.station?.lon ?? 0)")
            r.cancelFly()

            // Filter: picking only finds the chosen type.
            for o in OrbitClass.allCases {
                app.orbitFilter = o
                try? await Task.sleep(for: .milliseconds(100))
                let hit = r.pick(at: c, radius: 400)
                expect("filter \(o.rawValue) picks only \(o.rawValue)", hit == nil || hit?.orbit == o, hit?.name ?? "none on this side")
            }
            app.orbitFilter = nil

            // Radar agrees with an independent look at the same moment.
            try? await Task.sleep(for: .seconds(3))
            guard let st = app.station else { return }
            log("radar: \(radar.blips.count) in view, \(radar.approaches.count) approaching")
            var wrong = 0
            for b in radar.blips.prefix(300) {
                guard let s = store.satellite(norad: b.id)?.clone() else { continue }
                let jd = Astro.julianDate()
                guard let state = s.state(jd: jd) else { continue }
                let l = Astro.lookAngles(target: Astro.ecef(state.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon)
                if abs(l.el - b.elevation) > 3 { wrong += 1 }
            }
            let shown = RadarTracker.passing(radar.blips, filter: nil)
            expect("radar shows only what's passing", shown.count <= RadarTracker.maxShown && shown.allSatisfy { $0.elevation >= RadarTracker.passElevation && $0.orbit != .geo }, "\(shown.count) of \(radar.blips.count) above the horizon")
            expect("blips match a direct calculation", !radar.blips.isEmpty && wrong == 0, "\(wrong) disagree")
            let next = Array(radar.approaches.filter { $0.aos > Date() }.prefix(10))
            expect("ten satellites approaching", next.count == 10, "\(next.count)")
            var early = 0, late = 0
            for a in next {
                guard let s = store.satellite(norad: a.id)?.clone() else { continue }
                func el(_ d: Date) -> Double {
                    let jd = Astro.julianDate(d)
                    guard let state = s.state(jd: jd) else { return -90 }
                    return Astro.lookAngles(target: Astro.ecef(state.r, gmst: Astro.gmst(jd)), latDeg: st.lat, lonDeg: st.lon).el
                }
                let mask = RadarTracker.passElevation
                if el(a.aos.addingTimeInterval(-10)) > mask + 0.5 { early += 1 }
                if el(a.aos.addingTimeInterval(10)) < mask { late += 1 }
                log("  \(s.name) \(s.orbit.rawValue) \(store.satellite(norad: a.id)?.countryISO ?? "") in \(Int(a.aos.timeIntervalSinceNow)) s")
            }
            expect("each rises when predicted", early == 0 && late == 0, "early=\(early) late=\(late)")

            // With a filter on, the radar must still fill from what the filter allows.
            let amateur = store.satellites.filter { !UplinkPolicy.listedUplinks(for: $0).isEmpty || $0.category == .amateur }
            app.satelliteFilter.onlyNorads = Set(amateur.map(\.norad))
            try? await Task.sleep(for: .seconds(6))
            let allowed = Set(amateur.map(\.norad))
            let up = radar.blips.filter { allowed.contains($0.id) && $0.elevation >= 0 && $0.orbit != .geo && $0.orbit != .deep }
            let shownNow = RadarTracker.passing(radar.blips, filter: nil) { allowed.contains($0) }
            expect("a filter narrows the radar without emptying it", shownNow.count == min(up.count, RadarTracker.maxShown) && shownNow.allSatisfy { allowed.contains($0.id) }, "\(shownNow.count) shown of \(up.count) allowed and up, from \(amateur.count) in the filter")
            let coming = radar.approaches.filter { $0.aos > Date() }
            expect("approaching list is drawn from the filtered satellites", !coming.isEmpty && coming.allSatisfy { allowed.contains($0.id) }, "\(coming.count) coming, first \(coming.first.flatMap { store.satellite(norad: $0.id)?.name } ?? "-")")
            // And each agrees with the pass list to within a few seconds.
            var disagree = 0
            for a in coming.prefix(5) {
                guard let s = store.satellite(norad: a.id)?.clone(), let p = PassPredictor.passes(s, lat: st.lat, lon: st.lon, hours: 4).first(where: { $0.aos > Date().addingTimeInterval(-5) }) else { continue }
                if abs(p.aos.timeIntervalSince(a.aos)) > 5 { disagree += 1; log("  \(s.name): radar \(a.aos.formatted(date: .omitted, time: .standard)), passes \(p.aos.formatted(date: .omitted, time: .standard))") }
            }
            expect("radar and pass list agree on rise times", disagree == 0, "\(disagree) differ by more than 5 s")
            app.satelliteFilter.onlyNorads = nil
            if let a = next.first, let s = store.satellite(norad: a.id) {
                app.lock(s)
                expect("choosing from the list locks it", app.locked?.norad == a.id, s.name)
            }
            log("DONE")
        }
    }

    /// A few rows from each status group, to show all the bar colours in one image.
    private static func hostSample(_ app: AppState) -> [SpyHost] {
        let all = app.sortedHosts()
        return [HostStatus.available, .unavailable, .dead].flatMap { s in all.filter { app.status(of: $0) == s }.prefix(3) }
    }

    /// Names on the spectrum, with a made-up span around the 70 cm satellite band over a real place.
    static func testLabels(store: SatelliteStore, app: AppState, path: String) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("labeltest: \(s)\n".utf8)) }
            app.station = Station(name: "Berlin", lat: 52.52, lon: 13.4, iso: "de")
            let feed = app.runner.spectrum
            feed.begin(frequency: 436.5e6, sampleRate: 3e6, mode: .listen)
            var noise = (0..<1024).map { _ in Float.random(in: -92 ... -86) }
            feed.update(noise); noise[500] = -60; feed.update(noise)
            app.showSpectrum = true
            let labels = WaterfallLabels()
            labels.attach(store: store, app: app)
            labels.refresh()
            log("\(labels.labels.count) signals named in 435-438 MHz over Berlin")
            var wrong = 0
            for l in labels.labels {
                guard let s = store.satellite(norad: l.norad)?.clone(), let st = s.state(jd: Astro.julianDate()) else { continue }
                let look = Astro.lookAngles(target: Astro.ecef(st.r, gmst: Astro.gmst(Astro.julianDate())), latDeg: 52.52, lonDeg: 13.4)
                if look.el < -1 || abs(l.hz - l.nominalHz - l.widthHz / 2) > 12_000 || abs(l.hz - 436.5e6) > 1.5e6 { wrong += 1 }
            }
            log("\(wrong == 0 && !labels.labels.isEmpty ? "PASS" : "FAIL") every named satellite is up, in the span, and within Doppler of its frequency (\(wrong) wrong)")
            for l in labels.labels.sorted(by: { $0.elevation > $1.elevation }).prefix(6) {
                log(String(format: "  %@ %.4f MHz (%+.1f kHz Doppler) %@ el %.0f", l.name, l.hz / 1e6, (l.hz - l.nominalHz - l.widthHz / 2) / 1e3, l.mode, l.elevation))
            }
            let r = ImageRenderer(content: SpectrumPanel(feed: feed, available: CGSize(width: 1120, height: 820), startExpanded: true, onClose: {}, labels: labels, lockedID: labels.labels.first?.norad)
                .environment(\.colorScheme, .dark).padding(10).background(Color(white: 0.1)))
            r.scale = 2
            writePNG(r.cgImage, path + ".png")
            if let first = labels.labels.max(by: { $0.elevation < $1.elevation }), let sat = store.satellite(norad: first.norad) {
                app.lock(sat); app.frequencyOverride = first.nominalHz
                log("\(app.locked?.norad == first.norad && app.frequency == first.nominalHz ? "PASS" : "FAIL") picking a name locks and tunes: \(sat.name) \(app.frequency ?? 0)")
                app.unlock()
            }
            feed.end(); app.showSpectrum = false
            log("DONE")
        }
    }

    static weak var liveSchedule: PassSchedule?

    /// The schedule against live orbits: it must lock whichever watched satellite is up, and stop when overridden.
    static func testSchedule(store: SatelliteStore, app: AppState) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("schedtest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            guard let schedule = liveSchedule else { log("FAIL no schedule"); return }
            app.autoListen = false
            app.unlock()
            app.station = Station(name: "Berlin", lat: 52.52, lon: 13.4, iso: "de")
            for n in schedule.watch { schedule.remove(n) }
            let jd = Astro.julianDate()
            func elevation(_ s: Satellite) -> Double {
                guard let st = s.clone()?.state(jd: jd) else { return -90 }
                return Astro.lookAngles(target: Astro.ecef(st.r, gmst: Astro.gmst(jd)), latDeg: 52.52, lonDeg: 13.4).el
            }
            let leo = store.satellites.filter { $0.orbit == .leo || $0.orbit == .sso }
            guard let up = leo.first(where: { let e = elevation($0); return e > 25 && e < 80 }) else { log("FAIL nothing overhead"); return }
            let down = Array(leo.filter { elevation($0) < -20 }.prefix(2))
            for s in down { schedule.add(s) }
            schedule.add(up)
            for _ in 0..<60 where schedule.isWorking || schedule.entries.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            expect("passes found for all three", Set(schedule.entries.map(\.norad)).count == 3, "\(schedule.entries.count) passes")
            schedule.isOn = true
            try? await Task.sleep(for: .seconds(3))
            expect("locks the satellite that's up now", app.locked?.norad == up.norad && schedule.active?.norad == up.norad, "\(up.name), locked \(app.locked?.name ?? "none")")
            expect("next is one of the others", schedule.next.map { $0.pass.aos > Date() } == true, schedule.next?.name ?? "-")
            if let other = down.first {
                app.lock(other)
                try? await Task.sleep(for: .seconds(3))
                expect("locking by hand stops the schedule", !schedule.isOn && app.locked?.norad == other.norad, schedule.note ?? "")
            }
            for n in schedule.watch { schedule.remove(n) }
            app.unlock()
            log("DONE")
        }
    }

    /// The window's planner, for scripted checks that run from static code.
    static weak var livePlanner: PassPlanner?

    /// Pass list against an independent check of each pass, then the panels rendered for a look.
    static func testPasses(store: SatelliteStore, app: AppState, planner: PassPlanner, path: String) {
        Task {
            let log = { (s: String) in FileHandle.standardError.write(Data("passtest: \(s)\n".utf8)) }
            func expect(_ n: String, _ ok: Bool, _ d: String = "") { log("\(ok ? "PASS" : "FAIL") \(n) \(d)") }
            guard let iss = store.satellite(norad: 25544) else { log("FAIL no ISS"); return }
            app.station = Station(name: "Bengaluru", lat: 12.977, lon: 77.574, iso: "in")
            app.lock(iss)
            for _ in 0..<40 where planner.passes.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            expect("passes found for the ISS", planner.passes.count >= 4, "\(planner.passes.count) in 48 h")
            var wrong = 0
            let check = iss.clone()!
            func el(_ d: Date) -> Double {
                let jd = Astro.julianDate(d)
                guard let s = check.state(jd: jd) else { return -90 }
                return Astro.lookAngles(target: Astro.ecef(s.r, gmst: Astro.gmst(jd)), latDeg: 12.977, lonDeg: 77.574).el
            }
            for p in planner.passes {
                let ok = el(p.aos.addingTimeInterval(-15)) < 0 && el(p.aos.addingTimeInterval(15)) > 0 && el(p.los.addingTimeInterval(-15)) > 0
                    && el(p.los.addingTimeInterval(15)) < 0 && abs(el(p.peak) - p.maxElevation) < 0.5
                if !ok, !p.isUp() { wrong += 1 }
            }
            expect("each pass rises, peaks and sets when listed", wrong == 0, "\(wrong) wrong")
            expect("passes are in order and don't overlap", zip(planner.passes, planner.passes.dropFirst()).allSatisfy { $0.los < $1.aos })
            if let geo = store.satellites.first(where: { $0.name.hasPrefix("GOES 18") })?.clone() {
                expect("a geostationary satellite has no passes", PassPredictor.passes(geo, lat: 12.977, lon: 77.574, hours: 24).isEmpty)
            }
            let w = PassPredictor.mutualWindows(iss.clone()!, here: (12.977, 77.574), there: Maidenhead.coordinates("MK80")!, days: 3)
            let far = PassPredictor.mutualWindows(iss.clone()!, here: (12.977, 77.574), there: Maidenhead.coordinates("FN31")!, days: 3)
            expect("nearby stations share windows, opposite sides of the world don't", !w.isEmpty && far.isEmpty, "\(w.count) near, \(far.count) far")
            planner.selected = planner.passes.first
            for (name, view) in [("passes", AnyView(PassesSection().frame(width: 300).padding(10))), ("radar", AnyView(RadarScope(blips: [], lockedID: nil, track: planner.passes.first?.track ?? []) { _ in }.frame(width: 186, height: 186).padding(10)))] {
                let r = ImageRenderer(content: view.environmentObject(app).environmentObject(planner).environmentObject(store).environmentObject(RadarTracker())
                    .environment(\.colorScheme, .dark).background(Color(white: 0.13)))
                r.scale = 2
                writePNG(r.cgImage, "\(path)-\(name).png")
            }
            log("DONE")
        }
    }

    nonisolated static func writePNG(_ cg: CGImage?, _ path: String) { write(cg, path) }

    nonisolated private static func write(_ cg: CGImage?, _ path: String) {
        guard let cg, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func take(path: String, sidebar: AnyView, renderer: GlobeRenderer?, app: AppState? = nil) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let root = win.contentView else { return }
        let r = ImageRenderer(content: sidebar.frame(width: 320).environment(\.colorScheme, .dark).background(Color(white: 0.13)))
        r.scale = 2
        write(r.cgImage, path + "-side.png")
        if arguments.contains("--scan-render"), let app, let sat = app.locked {
            let s = ImageRenderer(content: ScanSheet(satellite: sat).environmentObject(app).environmentObject(app.runner)
                .environment(\.colorScheme, .dark).background(Color(white: 0.13)))
            s.scale = 2
            write(s.cgImage, path + "-scan.png")
        }
        if let frame = root.superview ?? Optional(root), let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            write(rep.cgImage, path + "-window.png")
        }
        if arguments.contains("--flags") {
            let isos = ["cn","us","ru","in","gb","eu","un","jp","kr","kp","br","sa","tw","hk","fr","de","ca","au","za","tr","il","ae","mx","ar","es","it","eg","ir","pk","ng","kz","ua","sg","my","id","th","vn","ph","nz","lu"]
            let sheet = ImageRenderer(content: LazyVGrid(columns: Array(repeating: GridItem(.fixed(50)), count: 10), spacing: 8) {
                ForEach(isos, id: \.self) { FlagView(iso: $0, height: 28) }
            }.padding(10).frame(width: 560).background(Color(white: 0.2)))
            sheet.scale = 2
            write(sheet.cgImage, path + "-flags.png")
        }
        if let app = app {
            let rows = ImageRenderer(content: VStack(spacing: 0) {
                ForEach(Self.hostSample(app)) { h in
                    HostRow(host: h, selected: h.id == app.selectedHostID, status: app.status(of: h))
                }
            }.frame(width: 300).environment(\.colorScheme, .dark).background(Color(white: 0.13)))
            rows.scale = 2
            write(rows.cgImage, path + "-hosts.png")
        }
        if let scn = views(of: SCNView.self, in: root).first, let cg = scn.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil) {
            write(cg, path + "-model.png")
        }
        renderer?.captureNext = { cg in
            write(cg, path + "-globe.png")
            if let g = views(of: GlobeNSView.self, in: root).first {
                let frame = g.convert(g.bounds, to: nil)
                FileHandle.standardError.write(Data("globe view in window: \(frame) window width \(win.frame.width)\n".utf8))
                let hit = renderer?.pick(at: CGPoint(x: g.bounds.midX, y: g.bounds.midY), radius: 120)
                FileHandle.standardError.write(Data("view \(g.bounds.size); pick near centre: \(hit?.name ?? "none")\n".utf8))
            }
            FileHandle.standardError.write(Data("snapshot written\n".utf8))
        }
    }
}
