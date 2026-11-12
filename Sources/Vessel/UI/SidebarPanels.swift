import simd
import SwiftUI
import MapKit

// MARK: - Panel chrome

/// A collapsible stacked panel, in the manner of Photoshop's panel dock.
struct StackPanel<Content: View>: View {
    let title: String
    let symbol: String
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        _expanded = AppStorage(wrappedValue: true, "panel.\(title)")
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.65))

            Divider()
            if expanded {
                content
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
        }
    }
}

private struct InfoRow<V: View>: View {
    let label: String
    let value: V
    init(_ label: String, @ViewBuilder value: () -> V) { self.label = label; self.value = value() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
    }
}

func formatHz(_ hz: Double) -> String {
    if hz >= 1e9 { return String(format: "%.4f GHz", hz / 1e9) }
    if hz >= 1e6 { return String(format: "%.4f MHz", hz / 1e6) }
    return String(format: "%.1f kHz", hz / 1e3)
}

private func colorFor(_ o: OrbitClass) -> Color {
    let c = Palette.color(o)
    return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
}

// MARK: - Satellite panel

struct SatelliteSection: View {
    @StateObject private var models = SatelliteModelLoader()

    /// Says plainly what's on screen: the real spacecraft, a relative, or just a shape.
    private func modelCaption(_ sat: Satellite) -> String {
        switch models.state {
        case .loading: return "Loading 3D model…"
        case .ready: return models.choice?.caption ?? ""
        case .none, .failed: return SatelliteModel.kind(for: sat).caption + " (representative shape)"
        }
    }

    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.55))
                if let sat = app.locked {
                    SatelliteModelView(satellite: sat, model: models.node)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "cube.transparent").font(.system(size: 26, weight: .light))
                        Text("Click a satellite to lock it").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 170)
            .overlay(alignment: .bottomLeading) {
                if let sat = app.locked {
                    Text(modelCaption(sat))
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).padding(6)
                        .allowsHitTesting(false)
                }
            }

            .task(id: "\(app.locked?.norad ?? 0)|\(store.enrichmentVersion)") {
                models.load(app.locked.map(ModelCatalog.choice(for:)))
            }

            if let sat = app.locked {
                details(sat).id(store.enrichmentVersion)
            }
        }
    }

    /// Blank registry fields say so, rather than showing a gap.
    /// Blank in a listing means nobody's said. No listing at all means the catalogue hasn't reached it yet.
    @ViewBuilder private func registryText(_ value: String?, listed: Bool) -> some View {
        if let value, !value.isEmpty {
            Text(value).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } else {
            Text(listed ? "Not published" : "Not in the catalogue yet").foregroundStyle(.secondary)
                .help(listed ? "Its catalogue entry leaves this blank." : "GCAT, the catalogue this comes from, doesn't list this satellite yet. It's checked weekly.")
        }
    }

    /// Where it is, and how that's known: JPL's data, or worked out from its last fix.
    @ViewBuilder private func spacecraftPosition(_ sat: Satellite) -> some View {
        let jd = Astro.julianDate()
        VStack(alignment: .leading, spacing: 2) {
            if let km = sat.state(jd: jd).map({ simd_length($0.r) }) {
                Text("\(SpaceWords.distance(km)) from Earth").monospacedDigit()
                if sat.ephemeris?.isEstimated(jd) == true, let last = sat.ephemeris?.lastFixJD {
                    Text(String(format: "Estimated from speed and orbit, last fix %.1f days ago", jd - last))
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("From NASA JPL Horizons").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("Getting its position…").foregroundStyle(.secondary)
            }
            Button("Show in space") { app.showSpaceView() }.controlSize(.small)
            Text("Its signal is very weak here. Most need a large dish, so expect only noise on ordinary receivers.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func details(_ sat: Satellite) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(colorFor(sat.orbit))
            Text(sat.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).textSelection(.enabled)
            Spacer()
            Button { app.followLocked.toggle() } label: {
                Image(systemName: app.followLocked ? "scope" : "viewfinder")
            }
            .help(app.followLocked ? "Stop following" : "Keep this satellite centred")
            .buttonStyle(.borderless)
            Button { app.unlock() } label: { Image(systemName: "lock.open") }
                .help("Unlock")
                .buttonStyle(.borderless)
        }

        VStack(alignment: .leading, spacing: 4) {
            InfoRow("Country") {
                HStack(spacing: 5) {
                    FlagView(iso: sat.countryISO, height: 11)
                    Text(sat.countryName).lineLimit(1)
                }
            }
            InfoRow("NORAD number") { Text(String(sat.norad)).monospacedDigit().textSelection(.enabled) }
            InfoRow("Int'l designator") {
                Text(sat.registry?.designator.isEmpty == false ? sat.registry!.designator : sat.objectID.isEmpty ? "Unknown" : sat.objectID)
                    .monospacedDigit().textSelection(.enabled)
            }
            InfoRow("Operator") { registryText(sat.registry?.operatorName, listed: sat.registry != nil) }
            InfoRow("Built by") { registryText(sat.registry?.builder, listed: sat.registry != nil) }
            InfoRow("Mass") { registryText(sat.registry?.massKg.map { "\($0.formatted()) kg" }, listed: sat.registry != nil) }
            InfoRow("Bus") { registryText(sat.registry?.bus, listed: sat.registry != nil) }
            if sat.spaceObject == nil, SatelliteRegistry.isMissingDetails(sat.registry), let page = SatelliteRegistry.orbitalRadarPage(norad: sat.norad) {
                InfoRow("Look up") {
                    Link("View on Orbital Radar", destination: page).font(.system(size: 11))
                        .help("Opens this satellite's page on orbitalradar.com in your browser")
                }
            }
            InfoRow("Launched") { Text(sat.launchYear.map { String($0) } ?? "Unknown") }
            if let call = sat.callsign {
                InfoRow("Callsign") { Text(call).textSelection(.enabled) }
            }
            if sat.fromSatNOGS {
                InfoRow("Listing") {
                    Text("Reported as transmitting, with its orbit from SatNOGS. Not on CelesTrak's active list, so it may be old or intermittent.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if sat.clone()?.isDecayingNow == true {
                InfoRow("Position") {
                    Text(String(format: "Estimated: its orbit is decaying and may have ended. Last measured %.1f days ago.", Astro.julianDate() - sat.epochJD))
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let object = sat.spaceObject {
                InfoRow("Mission") { Text(object.about).fixedSize(horizontal: false, vertical: true) }
            }
            InfoRow("Category") {
                Label(sat.category.rawValue, systemImage: sat.category.symbol).labelStyle(.titleAndIcon)
            }
            if sat.ephemeris != nil {
                InfoRow("Position") { spacecraftPosition(sat) }
            } else {
            InfoRow("Orbit") {
                Text("\(sat.orbit.title), \(Int(sat.periodMinutes)) min, \(String(format: "%.1f", sat.inclination))°")
            }
            }
            InfoRow("Frequency") {
                if let f = app.frequency ?? sat.primaryDownlink?.downlinkHz {
                    let tx = sat.transmitters.min { abs($0.downlinkHz - f) < abs($1.downlinkHz - f) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(formatHz(f)).monospacedDigit()
                        if let note = sat.sharedWith {
                            Text(note).foregroundStyle(.secondary).font(.system(size: 10))
                        }
                        let near = tx.flatMap { abs($0.downlinkHz - f) < 100_000 ? $0 : nil }
                        SignalLabels(labels: SignalLabel.all(hz: f, mode: near?.mode)).padding(.vertical, 1)
                        if sat.transmitters.count > 1 {
                            Text("\(sat.transmitters.count) listed").foregroundStyle(.secondary).font(.system(size: 10))
                        }
                    }
                    if app.scanFrequency(for: sat) == f {
                        HStack(spacing: 6) {
                            Text("Found by scan, unconfirmed").foregroundStyle(.orange).font(.system(size: 10))
                            Button("Scan again") { app.showScan = true }.buttonStyle(.link).font(.system(size: 10))
                            Button("Forget") { app.forgetScannedFrequency(for: sat) }.buttonStyle(.link).font(.system(size: 10))
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Not publicly listed").foregroundStyle(.secondary)
                        Button("Scan") { app.showScan = true }
                            .controlSize(.mini)
                            .help("Search the likely bands for this satellite's signal")
                    }
                }
            }
            if sat.ephemeris == nil {
            InfoRow("Orbit data") {
                let days = Astro.julianDate() - sat.epochJD
                Text(days < 1 ? "Measured \(max(1, Int(days * 24))) hr ago" : "Measured \(Int(days)) days ago" + (days > DataUpdates.staleOrbitDays ? ", pass times may be off" : ""))
                    .foregroundStyle(days > DataUpdates.staleOrbitDays ? Color.orange : Color.primary)
            }
            }
            if !sat.communication.isEmpty {
                InfoRow("Talk through") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CommunicationKind.allCases.filter(sat.communication.contains).map(\.rawValue).joined(separator: ", "))
                            .fixedSize(horizontal: false, vertical: true)
                        if sat.talkThroughListedInactive {
                            Text("Listed, but not reported as working").foregroundStyle(.orange).font(.system(size: 10))
                        }
                    }
                }
            }
            if !sat.mediaKinds.isEmpty {
                InfoRow("Pictures") {
                    Text(MediaKind.allCases.filter(sat.mediaKinds.contains).map(\.rawValue).joined(separator: ", "))
                }
            }
            InfoRow("Encryption") {
                let e = sat.encryption
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: e.state.symbol ?? "questionmark.circle")
                        Text(e.state.rawValue)
                    }
                    Text(e.method).foregroundStyle(.secondary).font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("From the published design of this kind of system. No catalogue records it per satellite.")
            }
            if let st = app.station {
                Divider().padding(.vertical, 2)
                InfoRow("Next event") { passText(st) }
                if let az = app.azimuth, let el = app.elevation, let r = app.rangeKm {
                    InfoRow("Pointing") {
                        Text("Az \(Int(az))°  El \(String(format: "%.1f", el))°  \(Int(r).formatted()) km")
                            .monospacedDigit()
                            .foregroundStyle(el > 0 ? Color.primary : Color.secondary)
                    }
                }
            }
            SatNOGSSection(satellite: sat)
            TelemetrySection(satellite: sat)
        }
    }

    @ViewBuilder private func passText(_ st: Station) -> some View {
        switch app.pass {
        case .computing: Text("Predicting…").foregroundStyle(.secondary)
        case .unknown: Text("—").foregroundStyle(.secondary)
        case .alwaysVisible: Text("Always above horizon")
        case .none: Text("No pass in 3 days").foregroundStyle(.secondary)
        case .pass(let p):
            VStack(alignment: .leading, spacing: 1) {
                if p.inProgress {
                    Text("In view, leaves in ") + Text(p.los, style: .relative)
                } else {
                    Text("AOS in ") + Text(p.aos, style: .relative)
                }
                Text(PassWords.times(p)).foregroundStyle(.secondary).font(.system(size: 10))
            }
        }
    }
}

// MARK: - Listener panel

/// The list of sources, grouped by kind, opened at the pointer.
@MainActor
enum SourceMenu {
    private final class Item: NSMenuItem {
        var choose: (() -> Void)?
        @objc func fire() { choose?() }
    }

    struct Entry: Equatable {
        let id: String
        let title: String
    }

    /// Hardware lists only what's plugged in, as there's nothing to choose about the rest.
    static func sections(attached: [AttachedHardware]) -> [(title: String, entries: [Entry])] {
        let hardware = attached.map { Entry(id: $0.sourceID, title: $0.title) }
        return [SDRSource.Kind.spy, .network].map { kind in
            (kind.rawValue, SDRCatalog.sources.filter { $0.kind == kind }.map { Entry(id: $0.id, title: $0.name) })
        } + [(SDRSource.Kind.usb.rawValue, hardware)]
    }

    static func show(current: String, attached: [AttachedHardware], choose: @escaping (String) -> Void) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for section in sections(attached: attached) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in section.entries {
                let item = Item(title: entry.title, action: #selector(Item.fire), keyEquivalent: "")
                item.target = item
                item.state = entry.id == current ? .on : .off
                item.choose = { choose(entry.id) }
                menu.addItem(item)
            }
            if section.entries.isEmpty {
                let none = NSMenuItem(title: "Nothing plugged in", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

struct ListenerSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var rotator: RotatorController
    @State private var countryQuery = Snapshot.arguments.firstIndex(of: "--country-search").map { Snapshot.arguments[$0 + 1] } ?? ""
    @State private var showCountries = Snapshot.arguments.contains("--country-search")
    @FocusState private var countryFocused: Bool
    @State private var showSatellitePicker = Snapshot.arguments.contains("--satellite-picker")

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Source").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                // A plain button opening a menu, as a system picker won't stretch to match the Rotator row.
                Button { SourceMenu.show(current: app.sourceID, attached: app.attachedHardware) { app.sourceID = $0 } } label: {
                    HStack(spacing: 6) {
                        Text(app.source.name).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(SelectorButtonStyle())
                .disabled(runner.isRunning)
                .accessibilityLabel("Source: \(app.source.name)")
            }

            RotatorStrip(rotator: rotator)
            if app.source.kind == .usb { hardware }
            if app.source.kind == .network { networkFields }

            if let host = app.pinnedHost {
                stationLine
                pinned(host)
            } else if app.source.kind == .spy {
                countrySearch
                stationLine
                hostList
            } else {
                // Off the public networks, the place is your own, set from the bar on the globe.
                HStack(spacing: 5) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                    Text(app.station == nil ? "Set your location in the address bar on the globe" : "Your location, from the address bar on the globe")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                stationLine
            }
        }
        .onChange(of: app.sourceID) { _, _ in
            // Listening through someone else's receiver, your own antenna has no part to play.
            if !app.supportsRotator { rotator.stop() }
            if app.source.kind != .spy {
                app.selectedHostID = nil
                // A PlutoSDR on USB always answers at this address.
                app.address = app.source.id == "plutosdr" && app.attachedDevice(for: app.source) != nil ? "192.168.2.1" : ""
                app.port = app.source.defaultPort ?? 0
            }
            app.gain = min(max(app.gain, app.source.gainRange.lowerBound), app.source.gainRange.upperBound)
        }
    }

    private var hardware: some View {
        let device = app.attachedDevice(for: app.source)
        return HStack(spacing: 6) {
            Image(systemName: device == nil ? "cable.connector.slash" : "cable.connector")
                .foregroundStyle(device == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(device?.name ?? "No \(app.source.name) connected").font(.system(size: 11)).lineLimit(1)
                if device != nil, let ranges = app.receiverRanges {
                    Text((app.rtlTuner.map { "\($0.rawValue) tuner · " } ?? "") + SDRCatalog.describe(ranges))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var networkFields: some View {
        HStack(spacing: 6) {
            TextField("Address", text: $app.address).textFieldStyle(.roundedBorder).controlSize(.small)
            if app.source.defaultPort != nil {
                TextField("Port", value: $app.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 62)
            }
        }
    }

    @ViewBuilder private var stationLine: some View {
        if let st = app.station {
            HStack(spacing: 4) {
                if app.source.kind == .spy { FlagView(iso: st.iso, height: 11) }
                Text(st.name).lineLimit(1).truncationMode(.middle)
                Text(String(format: "%.3f°, %.3f°", st.lat, st.lon)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .font(.system(size: 10))
        }
    }

    /// Countries that have hosts on this network, best matches first.
    private var countrySuggestions: [(iso: String, name: String, count: Int)] {
        let q = countryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let hosts = app.hosts.filter { $0.network == app.hostNetwork && !$0.iso.isEmpty }
        let grouped = Dictionary(grouping: hosts, by: \.iso)
        return grouped.map { (iso: $0.key, name: $0.value[0].countryName, count: $0.value.count) }
            .filter { $0.name.lowercased().contains(q) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                return ap != bp ? ap : a.name < b.name
            }
            .prefix(6).map { $0 }
    }

    private func chooseCountry(_ name: String) {
        countryQuery = name
        showCountries = false
        countryFocused = false
    }

    /// Searching spy hosts is by country only, with suggestions that are only countries.
    private var countrySearch: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 18)
                TextField(app.pickingHostRegion ? "Click a region on the globe" : "Search by country", text: $countryQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($countryFocused)
                    .disabled(app.pickingHostRegion)
                    .onChange(of: countryQuery) { _, q in
                        if countryFocused { showCountries = true }
                        if !q.isEmpty { app.clearHostRegion(); app.hostsForSatellite = false }
                    }
                    .onChange(of: app.hostsForSatellite) { _, on in if on { countryQuery = "" } }
                    .onChange(of: app.hostRegion) { _, region in if region != nil { countryQuery = "" } }
                    .onChange(of: countryFocused) { _, focused in
                        // Late enough for a click on a suggestion to land first.
                        if !focused { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showCountries = false } }
                    }
                    .onSubmit { if let first = countrySuggestions.first { chooseCountry(first.name) } }
                    .onExitCommand { showCountries = false }
                if !countryQuery.isEmpty {
                    Button { countryQuery = ""; showCountries = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Show all countries")
                }
                regionPickButton
                satelliteButton
            }
            if let region = app.hostRegion { regionLine(region) }
            if app.hostsForSatellite { satelliteLine }
            let suggestions = showCountries ? countrySuggestions.filter { $0.name != countryQuery } : []
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.iso) { c in
                        Button { chooseCountry(c.name) } label: {
                            HStack(spacing: 6) {
                                FlagView(iso: c.iso, height: 11)
                                Text(c.name).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Text("\(c.count)").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
        }
    }

    /// The same control as the one in the address bar on the globe.
    private var regionPickButton: some View {
        Button {
            countryFocused = false
            showCountries = false
            app.pickingHostRegion.toggle()
        } label: {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 12))
                .foregroundStyle(app.pickingHostRegion ? Color.white : Color.primary)
                .frame(width: 22, height: 20)
                .background(app.pickingHostRegion ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(app.pickingHostRegion ? .cancelAction : nil)
        .help(app.pickingHostRegion ? "Cancel (Esc)" : "Click the globe to list the hosts around that spot")
        .accessibilityLabel("Find hosts by clicking the globe")
    }

    private static let satelliteIcon: NSImage? = {
        guard let u = Res.url("satellite.svg"), let img = NSImage(contentsOf: u) else { return nil }
        img.isTemplate = true
        return img
    }()

    private var satelliteButton: some View {
        Button {
            countryFocused = false
            showCountries = false
            app.hostsForSatellite = true
            showSatellitePicker = true
        } label: {
            Group {
                if let icon = Self.satelliteIcon {
                    Image(nsImage: icon).resizable().renderingMode(.template).aspectRatio(contentMode: .fit).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11))
                }
            }
            .foregroundStyle(app.hostsForSatellite ? Color.white : Color.primary)
            .frame(width: 22, height: 20)
            .background(app.hostsForSatellite ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose a satellite, and list the hosts that can hear it and when it reaches each")
        .accessibilityLabel("Find hosts that can hear a satellite")
        .popover(isPresented: $showSatellitePicker, arrowEdge: .bottom) {
            SatellitePicker(isPresented: $showSatellitePicker)
        }
    }

    private var satelliteLine: some View {
        let hours = Int(HostPasses.windowHours)
        let found = app.hostsHearingLocked().count
        let text: String
        if let sat = app.locked {
            if !app.hostArrivalsReady {
                text = "\(sat.name): working out passes…"
            } else if found > 0 {
                text = "\(sat.name): \(found) \(found == 1 ? "station" : "stations") in the next \(hours) hours"
            } else if let f = app.frequency {
                text = "\(sat.name): none can tune to \(formatHz(f)) in the next \(hours) hours"
            } else {
                text = "\(sat.name): none in the next \(hours) hours"
            }
        } else {
            text = "Waiting for a satellite. Click one on the globe."
        }
        return HStack(spacing: 5) {
            Image(systemName: app.locked == nil ? "hourglass" : "clock").foregroundStyle(.secondary).frame(width: 18)
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
        }
        .font(.system(size: 10))
    }

    private func regionLine(_ region: Station) -> some View {
        let radius = app.hostsAround(region).radiusKm
        return HStack(spacing: 5) {
            Circle().fill(Color(red: 0.2, green: 0.75, blue: 1)).frame(width: 6, height: 6).frame(width: 18)
            Text(region.name).lineLimit(1).truncationMode(.tail)
            Text(radius.map { "within \(Int($0).formatted()) km" } ?? "closest found")
                .foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 2)
            Button { app.clearHostRegion() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Show all hosts")
        }
        .font(.system(size: 10))
    }

    private var filteredHosts: [SpyHost] {
        if app.hostsForSatellite, app.locked != nil { return app.hostsHearingLocked() }
        if let region = app.hostRegion { return app.hostsAround(region).hosts }
        let q = countryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let all = app.sortedHosts()
        guard !q.isEmpty else { return all }
        return all.filter { $0.countryName.lowercased().contains(q) }
    }

    /// The connected host, alone. Double-clicking lets go of it and brings the list back.
    private func pinned(_ host: SpyHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HostRow(host: host, selected: true, status: app.status(of: host), connection: app.connectionDisplay(for: host),
                    detail: app.connectionDetail(for: host), link: app.hostLinks[host.id])
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.18)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture(count: 2) { app.disconnectHost() }
                .help(runner.isRunning ? "Stop listening to disconnect" : "Double-click to disconnect")
            Text(runner.isRunning ? "Connected. Stop listening to disconnect." : "Connected. Double-click it to disconnect and see the list.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostCounts: some View {
        let all = filteredHosts.map(app.status(of:))
        func item(_ s: HostStatus, _ c: Color) -> some View {
            HStack(spacing: 2) {
                Capsule().fill(c).frame(width: 2, height: 9)
                Text("\(all.filter { $0 == s }.count)").monospacedDigit()
            }
        }
        return Group {
            if all.isEmpty {
                Text(app.hostsStatus).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    item(.available, .green)
                    item(.unavailable, .yellow)
                    item(.dead, .red)
                }
                .foregroundStyle(.secondary)
                .help("Available, unavailable or full, and not responding")
            }
        }
        .font(.system(size: 10))
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(app.source.browserOnly ? "Web SDRs" : "Spy hosts").font(.system(size: 11, weight: .medium))
                hostCounts
                Spacer()
                Button { Task { await app.refreshHosts() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh host directory")
            }
            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach(filteredHosts) { h in
                        HostRow(host: h, selected: h.id == app.selectedHostID, status: app.status(of: h), connection: app.connectionDisplay(for: h),
                                detail: h.id == app.selectedHostID ? app.connectionDetail(for: h) : nil, link: app.hostLinks[h.id],
                                distanceKm: app.hostRegion.map { Astro.distanceKm(lat1: $0.lat, lon1: $0.lon, lat2: h.lat, lon2: h.lon) },
                                arrival: app.hostsForSatellite ? app.hostArrivals[h.id] : nil)
                            .onTapGesture { countryFocused = false; showCountries = false; app.selectHost(h) }
                    }
                }
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // A new search should show its results, not wherever the list was scrolled to.
            .onChange(of: app.hostSearchPlace) { _, _ in scroller.scrollTo("top", anchor: .top) }
            .onChange(of: app.hostRegion) { _, _ in scroller.scrollTo("top", anchor: .top) }
            .onChange(of: app.hostsForSatellite) { _, _ in scroller.scrollTo("top", anchor: .top) }
            .onChange(of: app.locked?.norad) { _, _ in scroller.scrollTo("top", anchor: .top) }
            .onChange(of: countryQuery) { _, _ in scroller.scrollTo("top", anchor: .top) }
            }
        }
    }
}

/// Five circles for how good the path to a host is. All empty until it's measured, or if it doesn't respond.
struct StrengthDots: View {
    let link: HostLink?

    private var color: Color {
        switch link?.bars ?? 0 {
        case 4...: .green
        case 3: .yellow
        default: .orange
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < (link?.bars ?? 0) ? color : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Connection strength: \(link?.word ?? "measuring")")
    }
}

struct HostRow: View {
    let host: SpyHost
    let selected: Bool
    let status: HostStatus
    var tooSlow = false
    var connection: HostConnection? = nil
    var detail: String? = nil
    var link: HostLink? = nil
    /// From the spot the list was narrowed to.
    var distanceKm: Double? = nil
    /// When the locked satellite reaches this host.
    var arrival: HostArrival? = nil

    private func clock(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Counts down on its own, like the radar's arrival time.
    private func arrivalText(_ a: HostArrival) -> Text {
        let height = Text(" · max \(Int(a.maxElevation))°")
        if a.inView() {
            let leaves = a.los.map { " · leaves \(clock($0))" } ?? ""
            return Text("In view now\(leaves)").foregroundColor(.green) + height
        }
        return Text("Arrives \(clock(a.aos)), in ") + Text(a.aos, style: .relative) + height
    }

    /// Shown under the selected host, as part of the same record.
    @ViewBuilder private var details: some View {
        if selected {
            VStack(alignment: .leading, spacing: 3) {
                if let detail { line("Status", detail) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Strength").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    StrengthDots(link: link)
                    .help("From round-trip time and lost connection attempts. This doesn't measure spare bandwidth.")
                    Text(strengthText).monospacedDigit()
                }
                line("Location", host.city.isEmpty ? host.countryName : "Near \(host.placeName)")
                line("Address", "\(host.host):\(host.port)")
                line("Device", host.resolutionBits > 0 ? "\(host.device), \(host.resolutionBits)-bit" : host.device)
                line("Range", "\(Int(host.minHz / 1e6)) to \(Int(host.maxHz / 1e6)) MHz")
                if host.maxSampleRate > 0 { line("Max rate", formatHz(host.maxSampleRate).replacingOccurrences(of: "Hz", with: "S/s")) }
                line("Listeners", "\(host.clients) of \(host.maxClients)")
                if host.network == .spyServer { line("Tuning", host.fullControl ? "Open to listeners" : "Restricted by the owner") }
                if !host.antenna.isEmpty { line("Antenna", host.antenna) }
                if !host.details.isEmpty { line("Notes", host.details) }
            }
            .font(.system(size: 10))
            .padding(.leading, 9).padding(.top, 4).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var strengthText: String {
        guard let link else { return "Measuring…" }
        guard let ms = link.roundTripMs else { return link.word }
        return "\(link.word), \(Int(ms)) ms" + (link.lost > 0 ? ", \(link.lost) of 3 lost" : "")
    }

    @ViewBuilder private var connectionMark: some View {
        switch connection {
        case .connecting:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14).help("Connecting…")
        case .connected:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green).help("Connected")
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red).help("Couldn't connect")
        case nil:
            EmptyView()
        }
    }

    private var barColor: Color {
        switch status {
        case .available: .green
        case .unavailable: .yellow
        case .dead: .red
        case .checking: .gray
        }
    }

    private var statusText: String {
        switch status {
        case .available: "Available"
        case .unavailable: tooSlow ? "Connection too slow for this signal" : host.isFull ? "Full" : (host.network == .spyServer && !host.fullControl ? "Owner restricts retuning" : "Can't reach this frequency")
        case .dead: "Not responding"
        case .checking: "Checking…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            details
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .help("\(statusText)\n\(host.details.isEmpty ? "" : host.details + "\n")\(host.host):\(host.port)")
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Capsule().fill(barColor).frame(width: 3, height: 20)
            // Only the row dims, so a dead host keeps a clearly red bar.
            HStack(spacing: 6) {
                FlagView(iso: host.iso, height: 12)
                    .saturation(status == .dead ? 0 : 1)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(host.shortName).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        if host.network == .spyServer, !host.fullControl {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                    Text((distanceKm.map { "\(Int($0).formatted()) km · " } ?? "") + "\(host.device) · \(Int(host.minHz / 1e6).formatted()) to \(Int(host.maxHz / 1e6).formatted()) MHz")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    if let arrival {
                        arrivalText(arrival).font(.system(size: 9, weight: .medium)).lineLimit(1).monospacedDigit()
                    }
                }
                Spacer(minLength: 2)
                connectionMark
                VStack(alignment: .trailing, spacing: 3) {
                    StrengthDots(link: link).help("Connection: \(strengthText)")
                    Text("\(host.clients)/\(host.maxClients)")
                        .font(.system(size: 9)).monospacedDigit()
                        .foregroundStyle(host.isFull ? Color.yellow : Color.secondary)
                }
            }
            .opacity(status == .dead ? 0.5 : 1)
        }
    }
}

/// What the signal is: what the listing says, and what's actually been detected.
struct FormatRow: View {
    @ObservedObject var formats: FormatMonitor
    @ObservedObject var packets: PacketMonitor
    @ObservedObject var sstv: SSTVMonitor
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner

    /// Decoded data is proof. What the audio sounds like is only a judgement, and says so.
    private var detected: (text: String, sure: Bool)? {
        guard runner.isRunning else { return nil }
        if let p = packets.packets.first { return (p.report != nil ? "APRS, packets decoded" : "AX.25 packet, decoded", true) }
        if sstv.live != nil || !sstv.finished.isEmpty { return ("SSTV, picture decoding", true) }
        if let lock = runner.lockText, lock.lowercased().contains("lock"), !lock.lowercased().contains("no ") {
            return ("Decoder locked on", true)
        }
        if let s = formats.sound { return ("Sounds like \(s.rawValue)", false) }
        return nil
    }

    private var checking: String? {
        guard runner.isRunning, detected == nil else { return nil }
        return runner.mode == .listen ? "Checking the signal…" : "Not checked: Save to file only has no audio to check"
    }

    var body: some View {
        if app.locked != nil {
            Group {
                formatLine
                if let detected {
                    detectedLine(detected.text, sure: detected.sure)
                } else if let checking {
                    detectedLine(checking, sure: nil)
                }
                if let f = app.listedFormat {
                    line2(f.capture)
                }
            }
        }
    }

    private var formatLine: some View {
        InfoRow("Format") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let f = app.listedFormat {
                    Text(f.rawValue).fontWeight(.medium)
                    Text(f.group.rawValue).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(app.frequency == nil ? "Unknown" : "Not listed").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detectedLine(_ text: String, sure: Bool?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Color.clear.frame(width: 84, height: 1).fixedSize()
            Image(systemName: sure == true ? "checkmark.circle.fill" : sure == false ? "ear" : "ellipsis.circle")
                .font(.system(size: 9)).foregroundStyle(sure == true ? Color.green : Color.secondary)
            Text(text).font(.system(size: 10)).foregroundStyle(sure == true ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line2(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Color.clear.frame(width: 84, height: 1).fixedSize()
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The spacecraft button in the globe's legend: telescopes, lunar orbiters and probes by group.
struct SpacecraftList: View {
    let close: () -> Void
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SpaceObject.Kind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.rawValue).font(.system(size: 11, weight: .semibold))
                        Text(kind.explanation).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
                        ForEach(SpaceCatalog.of(kind: kind)) { o in
                            Button {
                                close()
                                app.openSpaceObject(o, store: store)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(OrbitClass.spacecraft.color).frame(width: 6, height: 6)
                                    Text(o.name).font(.system(size: 11)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    if app.locked?.norad == o.noradID {
                                        Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(.green)
                                    }
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 300, height: 420)
    }
}

/// The guide behind the satellite button: choose one here, or click it on the globe.
struct SatellitePicker: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore
    @State private var query = ""

    /// Good first picks: satellites people can actually talk through or get pictures from.
    private var suggestions: [Satellite] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return store.search(q, limit: 8) }
        return Array(store.satellites.filter { !$0.communication.isEmpty || !$0.media.isEmpty }
            .sorted { a, b in
                let aISS = a.norad == CommunicationKind.issNorad, bISS = b.norad == CommunicationKind.issNorad
                return aISS != bISS ? aISS : a.name < b.name
            }
            .prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sat = app.locked {
                Label("Showing stations for \(sat.name)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                Text("Choose another below, or click one on the globe.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Label("Waiting for a satellite", systemImage: "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                Text("Choose one below, or click any satellite on the globe. You'll then see which stations can hear it, and when it reaches each.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Search by name or NORAD ID", text: $query)
                .textFieldStyle(.roundedBorder).controlSize(.small)
            if !query.isEmpty, suggestions.isEmpty {
                Text("No satellite matches that.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { sat in
                    Button {
                        app.lock(sat)
                        isPresented = false
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(sat.orbit.color).frame(width: 6, height: 6)
                            Text(sat.name).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 4)
                            if sat.id == app.locked?.id {
                                Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Show all hosts") {
                    app.hostsForSatellite = false
                    isPresented = false
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
        // Clicking on the globe locks a satellite without going through this list.
        .onChange(of: app.locked?.norad) { _, norad in if norad != nil { isPresented = false } }
    }
}

/// The picture and video downlinks a satellite offers, used by the Capture and Transmit panels.
struct MediaSignalList: View {
    let satellite: Satellite
    var disabled = false
    var action = "Tune"
    let tune: (MediaSignal) -> Void
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(satellite.media) { m in
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.title).fontWeight(.medium).lineLimit(1)
                        Text(formatHz(m.hz)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 2)
                    if app.activeMedia == m {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                            .help("Tuned to this")
                    } else {
                        Button(action) { tune(m) }.controlSize(.mini).disabled(disabled)
                    }
                }
            }
            let unlisted = MediaKind.allCases.filter { k in satellite.amsatMedia.contains(k) && !satellite.media.contains { $0.kind == k } }
            if !unlisted.isEmpty {
                Text("\(unlisted.map(\.rawValue).joined(separator: ", ")): AMSAT tracks it, but no frequency is listed")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Capture panel

struct CaptureSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner
    @EnvironmentObject var rotator: RotatorController

    /// Mutes or plays what's being received through this computer.
    private var speakerButton: some View {
        let on = app.speakerOn && app.speakerProblem == nil
        return Button { app.speakerOn.toggle() } label: {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(width: 20)
        }
        .controlSize(.regular)
        .disabled(app.speakerProblem != nil)
        .help(app.speakerProblem ?? (on ? "Mute this computer" : "Listen through this computer"))
        .accessibilityLabel(on ? "Mute" : "Listen through this computer")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Anything in the way comes first, right under the title.
            CaptureNotices(problem: app.startProblem, warnings: warningTexts.filter { $0 != app.startProblem?.message },
                           error: app.captureError ?? runner.lastError) { app.listenOutput = .file }
            if runner.executable == nil {
                Label("This copy of Vessel is missing its receiving engine. Download Vessel again to fix it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                InfoRow("Frequency") {
                    if let f = app.frequency {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                            Text(formatHz(f)).monospacedDigit().fontWeight(.medium)
                            let tx = app.locked?.transmitters.min { abs($0.downlinkHz - f) < abs($1.downlinkHz - f) }
                            SignalLabels(labels: SignalLabel.all(hz: f, mode: tx.flatMap { abs($0.downlinkHz - f) < 100_000 ? $0.mode : nil }))
                        }
                    } else {
                        Text(app.locked == nil ? "Lock a satellite" : "Not publicly listed").foregroundStyle(.secondary)
                    }
                }
                downlinkPicker
                FormatRow(formats: app.formats, packets: app.packets, sstv: app.sstv)
                mediaRows
                SSTVPanel(monitor: app.sstv, expecting: app.activeMedia?.kind == .sstv)
                PacketPanel(monitor: app.packets, expecting: app.expectsPackets, station: app.station, norad: app.locked?.satnogsNorad,
                            callsign: UserDefaults.standard.string(forKey: "tx.callsign") ?? "") { lat, lon in
                    app.renderer?.fly(lat: Float(lat), lon: Float(lon))
                }
                FTPanel(monitor: app.ft, relevant: app.tunedTransponder != nil, saving: app.listenOutput == .file,
                        callsign: UserDefaults.standard.string(forKey: "tx.callsign") ?? "")
                InfoRow("Pipeline") {
                    Picker("", selection: Binding(
                        get: { app.pipelineOverrideID ?? "" },
                        set: { app.choosePipeline($0.isEmpty ? nil : $0) }
                    )) {
                        Text(app.tune.pipeline.map { "Automatic: \($0.name)" } ?? (app.locked == nil ? "Automatic" : "Automatic: save to file")).tag("")
                        Divider()
                        ForEach(runner.catalog.pipelines.filter(\.liveCapable)) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(app.locked == nil || runner.isRunning)
                }
                if app.pipelineOverrideID != nil {
                    InfoRow("") { Text("Chosen by hand, and remembered for this satellite").foregroundStyle(.secondary).font(.system(size: 10)) }
                } else if !app.tune.reason.isEmpty, app.tune.reason != "Automatic", app.tune.pipeline == nil {
                    InfoRow("") {
                        Text(app.tune.reason).foregroundStyle(.secondary).font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                InfoRow("Sample rate") {
                    HStack(spacing: 4) {
                        Text(formatHz(app.sampleRate).replacingOccurrences(of: "Hz", with: "S/s")).monospacedDigit()
                        if app.source.kind == .spy, app.matchHostRate, !app.source.browserOnly {
                            Text("8-bit, matched to the signal").foregroundStyle(.secondary).font(.system(size: 10)).lineLimit(1)
                        }
                    }
                }
            }


            VStack(alignment: .leading, spacing: 3) {
                Picker("", selection: $app.listenOutput) {
                    ForEach(ListenOutput.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .disabled(runner.isRunning)
                Text(app.listenOutput == .decode
                     ? "Decodes as it receives, then makes images and products when it stops."
                     : "Saves the raw signal only, about \(app.fileRateText), for decoding later.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Auto listen when satellite is in range", isOn: $app.autoListen)
                .controlSize(.small)
                .font(.system(size: 11))
                .help("Starts when the locked satellite rises above the horizon at your location, with its frequency, decoder and rate. Stops when it sets.")
            if app.autoListen, !app.autoStatus.isEmpty {
                Text(app.autoStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Automatic gain (AGC)", isOn: app.agcBinding)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .disabled(app.agcSpec == nil)
                Text(app.agcSpec?.summary ?? SDRCatalog.noAGCReason(app.source))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 5) {
                Text("Stop at").font(.system(size: 11))
                TextField("No limit", value: $app.sizeLimitMB, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .disabled(runner.isRunning)
                    .help("Stops the capture once its files reach this size. Leave empty for no limit.")
                Text("MB").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 6) {
                if app.source.browserOnly {
                    Button {
                        if let u = app.selectedHost?.webURL { NSWorkspace.shared.open(u) }
                    } label: {
                        Label("Open in browser", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .disabled(app.selectedHost?.webURL == nil)
                    .help("Web receivers can't be streamed, so decoding and recording aren't available")
                } else if runner.isProcessing {
                    Label("Processing results…", systemImage: "gearshape.2")
                        .frame(maxWidth: .infinity)
                        .font(.system(size: 12))
                } else if runner.isRunning {
                    Button(role: .destructive) { app.stopCapture() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                } else {
                    Button { app.startListening() } label: {
                        Label("Start listening", systemImage: app.listenOutput == .decode ? "headphones" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!app.canStartListening)
                    .help(app.listenOutput == .decode ? "Run the decoder live" : "Save the raw signal to disk")
                }
                if !app.source.browserOnly { speakerButton }
            }

            if let note = app.captureNote {
                Label(note, systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
            }

            RotatorBox(rotator: rotator)
            signalMeter

            if runner.isRunning || app.showSpectrum {
                Button {
                    app.showSpectrum.toggle()
                } label: {
                    Label(app.showSpectrum ? "Hide spectrum" : "Show spectrum", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Opens a live spectrum at the top right of the globe")
            }

            DisclosureGroup("Options") { options.padding(.top, 4) }
                .font(.system(size: 11))

            DisclosureGroup("Log") { logView.padding(.top, 4) }
                .font(.system(size: 11))
        }
    }

    /// Picture and video signals this satellite sends, and what capturing one does.
    @ViewBuilder private var mediaRows: some View {
        if let sat = app.locked, !sat.mediaKinds.isEmpty {
            InfoRow("Pictures") {
                MediaSignalList(satellite: sat, disabled: runner.isRunning) { app.tuneMedia($0) }
            }
            if let active = app.activeMedia {
                InfoRow("") {
                    Text((runner.isRunning ? "Receiving \(active.title). " : "") + active.captureAdvice)
                        .foregroundStyle(.secondary).font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var downlinkPicker: some View {
        if let sat = app.locked {
            // Only what this receiver could actually tune to.
            let ranges = app.source.kind == .spy ? nil : app.receiverRanges
            let txs = Self.uniqueDownlinks(sat).filter { t in ranges.map { $0.contains { $0.contains(t.downlinkHz) } } ?? true }
            if txs.count > 1 {
                InfoRow("Downlink") {
                    Picker("", selection: Binding(
                        get: { app.frequency ?? 0 },
                        set: { app.frequencyOverride = $0 }
                    )) {
                        if let f = app.tune.frequencyHz, !txs.contains(where: { $0.downlinkHz == f }) {
                            Text("\(formatHz(f)) (pipeline)").tag(f)
                        }
                        ForEach(txs, id: \.self) { t in
                            Text("\(formatHz(t.downlinkHz)) \(MediaSignal.kind(of: t)?.rawValue ?? t.mode)").tag(t.downlinkHz)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(runner.isRunning)
                }
            }
        }
    }

    private static func uniqueDownlinks(_ sat: Satellite) -> [Transmitter] {
        var seen = Set<Double>()
        return sat.transmitters.filter { $0.active && $0.downlinkHz > 0 && seen.insert($0.downlinkHz).inserted }
    }

    private var warningTexts: [String] {
        var w: [String] = []
        guard let sat = app.locked else { return w }
        // Only while the demodulator is standing in, not once one's been chosen by hand.
        if app.usingDemodulatorForLackOfDecoder {
            w.append(StartProblem.noDecoder(satellite: sat.name, encryption: sat.encryption.state) + " Using the demodulator.")
        }
                if app.source.kind == .spy {
            if let h = app.selectedHost {
                if let f = app.frequency, !h.covers(f) { w.append("This host cannot tune \(formatHz(f)).") }
                if !h.fullControl { w.append("This host's owner restricts retuning.") }
                if h.isFull { w.append("This host is full.") }
                if app.hostReachable == false { w.append("This host is not answering. Pick another.") }
                if let short = app.rateShortfall { w.append(short) }
            } else {
                w.append("Pick a spy host.")
            }
        }
        return w
    }

    /// A row of balls that go from red to green as the signal strengthens.
    private var signalMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                let lit = SignalScale.lit(snr: runner.snr)
                ForEach(0..<SignalScale.count, id: \.self) { i in
                    SignalBall(on: runner.isRunning && i < lit, active: runner.isRunning)
                }
            }
            HStack {
                if let s = runner.snr {
                    Text(String(format: "SNR %.1f dB", s)).monospacedDigit()
                        .help("Signal to noise: how far the signal stands above the noise, not how strong it is. More gain lifts the noise too, so this won't always rise with it.")
                    if let p = runner.peakSNR { Text(String(format: "peak %.1f", p)).foregroundStyle(.secondary).monospacedDigit() }
                } else {
                    Text(app.testingSpeed ? "Testing the host's speed…" : app.isPreparing ? "Contacting host…" : runner.isRunning ? "Starting the receiver…" : "Idle").foregroundStyle(.secondary)
                }
                Spacer()
                if let l = runner.lockText { Text(l).foregroundStyle(l.contains("locked") ? .green : .secondary) }
                if let b = runner.bytesWritten, b > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)).monospacedDigit() }
            }
            .font(.system(size: 10))
        }
        .padding(.vertical, 2)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Clock error").frame(width: 62, alignment: .leading)
                TextField("0", value: Binding(get: { app.ppm }, set: { app.ppm = $0 }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 56)
                Text("ppm").foregroundStyle(.secondary)
                if app.ppm != 0, let f = app.frequency {
                    Text(String(format: "%+.1f kHz here", FrequencyCorrection.error(at: f, ppm: app.ppm) / 1000)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .help("How far off this receiver's clock is, in parts per million. Tune to a signal of known frequency: if it appears too high, raise this. Remembered for each source.")
            if app.locked != nil, app.frequency != nil {
                HStack {
                    Text("Signal off").frame(width: 62, alignment: .leading)
                    TextField("0", value: Binding(get: { app.signalOffsetHz / 1000 }, set: { app.signalOffsetHz = $0 * 1000 }), format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 56)
                    Text("kHz from its listed frequency").foregroundStyle(.secondary)
                }
                .help("Many satellites transmit a few kHz away from where they're listed. Enter how far, and it's remembered for this signal.")
            }
            if let flag = app.source.gainFlag {
                HStack {
                    Text("Gain").frame(width: 62, alignment: .leading)
                    Slider(value: $app.gain, in: app.source.gainRange, step: 1) { editing in
                        if editing { app.gainIsManual = true }
                    }
                    .controlSize(.small)
                    // The engine takes its gain once, when it starts.
                    .disabled(app.agcReplacesGain || runner.isRunning)
                    Text("\(Int(app.gain))").monospacedDigit().frame(width: 22, alignment: .trailing)
                }
                .help(app.agcReplacesGain ? "AGC is setting the gain" : runner.isRunning ? "Stop listening to change the gain" : "Receiver gain, used from the next start")
            }
            if app.source.kind == .spy, !app.source.browserOnly {
                Toggle("Match rate to the signal and host", isOn: $app.matchHostRate).controlSize(.small)
                    .help("Uses the lowest rate and depth that hold this signal, and tests the host's speed first. Public hosts often can't send more, which leaves gaps.")
            }
            if !app.source.bitDepths.isEmpty {
                HStack {
                    Text("Bit depth").frame(width: 62, alignment: .leading)
                    Picker("", selection: $app.bitDepth) {
                        ForEach(app.source.bitDepths, id: \.self) { Text("\($0)-bit").tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                    .disabled(app.source.kind == .spy && app.matchHostRate)
                }
            }
            HStack {
                Text("Baseband").frame(width: 62, alignment: .leading)
                Picker("", selection: $app.basebandFormat) {
                    ForEach(["cf32", "cs32", "cs16", "cs8", "cu8", "wav16", "ziq"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().controlSize(.small)
                .disabled(app.source.kind == .spy && app.matchHostRate)
            }
            .help("File format used by Save to file only")
            if app.source.hasBias { Toggle("Bias-T power", isOn: $app.bias).controlSize(.small) }
            Toggle("DC block", isOn: $app.dcBlock).controlSize(.small)
            Toggle("Swap I/Q", isOn: $app.iqSwap).controlSize(.small)
            Toggle("Make images and products after stopping", isOn: $app.finishProcessing).controlSize(.small)
            Toggle("Stop automatically at loss of signal", isOn: $app.stopAtLOS).controlSize(.small)
            HStack {
                Text(app.outputDir.path(percentEncoded: false)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button("Output…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { app.outputDir = u }
                }
                .controlSize(.small)
            }
            if !runner.pipelineStatus.isEmpty {
                Label(runner.pipelineStatus, systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
        .disabled(runner.isRunning)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.3)))
            .onChange(of: runner.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }
}

enum SignalScale {
    static let count = 12
    /// SNR in dB for all balls lit: decoders generally hold lock from about 3 dB.
    static let fullScale = 15.0
    static func lit(snr: Double?) -> Int {
        guard let snr, snr > 0 else { return 0 }
        return min(count, Int((snr / fullScale * Double(count)).rounded(.up)))
    }
}

private struct SignalBall: View {
    let on: Bool
    let active: Bool
    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: on ? [Color(red: 0.6, green: 1, blue: 0.6), .green] : [Color(red: 1, green: 0.5, blue: 0.45), Color(red: 0.75, green: 0.1, blue: 0.1)],
                center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 9))
            .opacity(active ? 1 : 0.32)
            .frame(width: 13, height: 13)
            .shadow(color: on ? .green.opacity(0.75) : .clear, radius: 3)
            .animation(.easeOut(duration: 0.18), value: on)
    }
}

/// The look shared by the Source and Rotator rows: filling the column, with their contents starting at its left.
struct SelectorButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Everything standing in the way of a capture, together in one box under the Capture title.
struct CaptureNotices: View {
    let problem: StartProblem?
    let warnings: [String]
    let error: String?
    let saveInstead: () -> Void

    private var tint: Color { error != nil ? .red : .orange }

    var body: some View {
        if problem != nil || !warnings.isEmpty || error != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let error { row(error, symbol: "xmark.octagon.fill", color: .red, first: true) }
                if let problem {
                    VStack(alignment: .leading, spacing: 5) {
                        row(problem.message, symbol: "exclamationmark.circle.fill", color: .orange, first: error == nil)
                        if problem.canSaveInstead {
                            Button("Use Save to file instead", action: saveInstead)
                                .buttonStyle(.link).font(.system(size: 10, weight: .medium))
                                .padding(.leading, 21).padding(.bottom, 2)
                        }
                    }
                }
                ForEach(Array(warnings.enumerated()), id: \.element) { i, w in
                    row(w, symbol: "exclamationmark.triangle.fill", color: .orange, first: i == 0 && error == nil && problem == nil)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
        }
    }

    private func row(_ text: String, symbol: String, color: Color, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Divider().padding(.vertical, 5) }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
                Text(text).font(.system(size: 11)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
