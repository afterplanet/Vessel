import Foundation
import simd
import Metal
import SwiftUI

enum AppFolders {
    /// True inside the test runner, so tests never write into someone's real folders.
    static let isTesting = NSClassFromString("XCTestCase") != nil
}

enum Res {
    /// SwiftPM's `Bundle.module` only looks beside the .app, not inside it, so check there first.
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Vessel_Vessel.bundle"),
           let b = Bundle(url: url) { return b }
        return Bundle.module
    }()
    static func url(_ path: String) -> URL? {
        // The Resources folder is copied whole, and bundle layouts differ between build systems.
        let fm = FileManager.default
        for base in [bundle.resourceURL?.appendingPathComponent("Resources"), bundle.resourceURL] {
            if let u = base?.appendingPathComponent(path), fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
    static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vessel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Polite cached fetch: serves the cache if it is younger than `maxAge`, otherwise tries the
/// network and falls back to whatever stale copy exists.
enum DataFetcher {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 300
        c.httpAdditionalHeaders = ["User-Agent": "Vessel/1.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    /// Starts from a cached copy if it's reasonably recent, so a slow network can't hold up the
    /// app. A fresh copy is fetched behind the scenes for next time.
    static func preferCached(_ urlString: String, cacheName: String, refreshAfter: TimeInterval, usableFor: TimeInterval) async throws -> Data {
        let file = Res.cacheDir.appendingPathComponent(cacheName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let mod = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(mod) < usableFor,
           let d = try? Data(contentsOf: file), !d.isEmpty {
            if Date().timeIntervalSince(mod) > refreshAfter {
                Task.detached(priority: .utility) { _ = try? await data(urlString, cacheName: cacheName, maxAge: refreshAfter) }
            }
            return d
        }
        return try await data(urlString, cacheName: cacheName, maxAge: refreshAfter)
    }

    static func data(_ urlString: String, cacheName: String, maxAge: TimeInterval, userAgent: String? = nil, authorization: String? = nil) async throws -> Data {
        let file = Res.cacheDir.appendingPathComponent(cacheName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let mod = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(mod) < maxAge,
           let d = try? Data(contentsOf: file), !d.isEmpty { return d }
        do {
            var request = URLRequest(url: URL(string: urlString)!)
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            let (d, resp) = try await session.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { throw URLError(.badServerResponse) }
            try? d.write(to: file, options: .atomic)
            return d
        } catch {
            if let d = try? Data(contentsOf: file), !d.isEmpty { return d }
            throw error
        }
    }
}

@MainActor
final class SatelliteStore: ObservableObject {
    @Published private(set) var satellites: [Satellite] = []
    @Published private(set) var status = "Loading satellites…"
    @Published private(set) var enrichmentVersion = 0
    /// How many downlinks the JE9PEL list added that SatNOGS didn't have.
    var je9pelAdded = 0
    func noteEnrichment() { enrichmentVersion += 1 }
    @Published private(set) var lastUpdate: Date?
    private var byNorad: [Int: Satellite] = [:]

    private var classCounts: [OrbitClass: Int] = [:]

    func satellite(norad: Int) -> Satellite? { byNorad[norad] }
    func count(of o: OrbitClass) -> Int { classCounts[o] ?? 0 }

    @Published private(set) var launchYears: [Int] = []
    @Published private(set) var countries: [(name: String, iso: String, count: Int)] = []
    @Published private(set) var shownCounts: [OrbitClass: Int] = [:]
    @Published private(set) var categoryCounts: [SatCategory: Int] = [:]
    private var indexRows: [AMSATFrequencyIndex.Row] = []
    @Published private(set) var communicationCounts: [CommunicationKind: Int] = [:]
    @Published private(set) var mediaCounts: [MediaKind: Int] = [:]
    private var activeFilter = SatelliteFilter()
    private var frequencyTask: Task<Void, Never>?

    func shownCount(of o: OrbitClass?) -> Int {
        if let o { return shownCounts[o] ?? 0 }
        return shownCounts.values.reduce(0, +)
    }

    /// What the current receiver can tune. Nil if that isn't known, in which case nothing is hidden for it.
    private(set) var receiverRanges: [ClosedRange<Double>]?

    func setReceiverRanges(_ ranges: [ClosedRange<Double>]?) {
        guard ranges != receiverRanges else { return }
        receiverRanges = ranges
        if activeFilter.withinReceiver { reapplyFilter() }
    }

    func applyFilter(_ filter: SatelliteFilter) {
        activeFilter = filter
        var counts: [OrbitClass: Int] = [:]
        for s in satellites {
            let keep = filter.matches(launchYear: s.launchYear, encryption: s.encryption.state, hasFrequency: s.hasPublicFrequency, country: s.countryName, category: s.category, communication: s.communication, media: s.mediaKinds,
                                      reachable: !filter.withinReceiver || (receiverRanges.map(s.isReachable) ?? true))
            // A group shown alone narrows whatever else is chosen.
            let shown = keep && (filter.onlyNorads?.contains(s.norad) ?? true)
            s.filteredOut = !shown
            if shown { counts[s.orbit, default: 0] += 1 }
        }
        shownCounts = counts
        var byKind: [CommunicationKind: Int] = [:]
        var byMedia: [MediaKind: Int] = [:]
        for s in satellites {
            for k in s.communication { byKind[k, default: 0] += 1 }
            for k in s.mediaKinds { byMedia[k, default: 0] += 1 }
        }
        if byKind != communicationCounts { communicationCounts = byKind }
        var byCategory: [SatCategory: Int] = [:]
        for s in satellites { byCategory[s.category, default: 0] += 1 }
        if byCategory != categoryCounts { categoryCounts = byCategory }
        if byMedia != mediaCounts { mediaCounts = byMedia }
        launchYears = Array(Set(satellites.compactMap(\.launchYear))).sorted(by: >)
        // Only owners that map to a real country or body, not raw catalogue codes.
        var byCountry: [String: (iso: String, count: Int)] = [:]
        for s in satellites where !s.countryISO.isEmpty {
            byCountry[s.countryName, default: (s.countryISO, 0)].count += 1
        }
        let list = byCountry.map { (name: $0.key, iso: $0.value.iso, count: $0.value.count) }.sorted { $0.name < $1.name }
        if list.map(\.name) != countries.map(\.name) || list.map(\.count) != countries.map(\.count) { countries = list }
    }

    /// Whether each satellite has a frequency: one on SatNOGS, or one from a decoder for it.
    func refreshFrequencies(catalog: PipelineCatalog) {
        frequencyTask?.cancel()
        let all = UncheckedBox(satellites), box = UncheckedBox(catalog)
        frequencyTask = Task.detached(priority: .utility) { [weak self] in
            for s in all.value {
                if Task.isCancelled { return }
                let decoder = box.value.select(for: s).frequencyHz
                s.decoderFrequencyHz = decoder
                s.hasPublicFrequency = s.transmitters.contains { $0.downlinkHz > 0 } || decoder != nil
            }
            await self?.reapplyFilter()
        }
    }

    private func reapplyFilter() { applyFilter(activeFilter) }

    /// By name, NORAD number, or international designator in any of its usual forms.
    func search(_ query: String, limit: Int = 12) -> [Satellite] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [Satellite] = []
        if let n = Int(q) {
            if let s = byNorad[n] { hits.append(s) }
            // Typing a number shows matches as it grows.
            hits += satellites.filter { $0.norad != n && String($0.norad).hasPrefix(q) }.sorted { $0.norad < $1.norad }.prefix(limit)
        }
        if let designator = SatelliteRegistry.normalisedDesignator(q) {
            hits += satellites.filter {
                let own = $0.objectID.uppercased().replacingOccurrences(of: "-", with: "")
                return !own.isEmpty && (own == designator || own.hasPrefix(designator))
            }.sorted { $0.objectID < $1.objectID }
        }
        // Catalogue names can be cryptic: Hubble is listed as HST, and should come before things merely named after it.
        let spacecraft = satellites.filter { s in
            s.spaceObject?.name.lowercased().contains(q) == true || s.otherNames.contains { $0.lowercased().contains(q) }
        }
        let named = satellites.filter { $0.name.lowercased().contains(q) }.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(q), pb = b.name.lowercased().hasPrefix(q)
            return pa != pb ? pa : a.name < b.name
        }
        var seen = Set<Int>()
        return Array((hits + spacecraft + named).filter { seen.insert($0.norad).inserted }.prefix(limit))
    }

    /// Bumped each time the catalogue is replaced, even by one the same size.
    @Published private(set) var catalogVersion = 0
    @Published private(set) var positionsVersion = 0

    /// Downloads newer orbits if they're due and reloads. False if the download failed.
    @discardableResult
    func reload(force: Bool = false) async -> Bool {
        let url = "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=json"
        let before = DataUpdates.age(of: "gp_active.json") ?? .infinity
        // Still respects their limit: it won't fetch inside two hours, whatever asks.
        _ = try? await DataFetcher.data(url, cacheName: "gp_active.json", maxAge: 7200)
        let after = DataUpdates.age(of: "gp_active.json") ?? .infinity
        await load()
        return after < before || after < 7200
    }

    /// Fetches the other datasets that have come due.
    func refreshDue() async {
        async let a: Void = loadSatcat()
        async let b: Void = loadTransmitters()
        async let c: Void = loadAMSATMedia()
        _ = await (a, b, c)
        await loadJE9PEL()
        async let d: Void = loadFrequencyIndex()
        async let e: Void = loadRegistry()
        async let f: Void = loadOtherNames()
        _ = await (d, e, f)
        linkStationParts()
        linkListedTalkThrough()
        enrichmentVersion += 1
        reapplyFilter()
    }

    private let spaceEphemerides: [(object: SpaceObject, ephemeris: SpaceEphemeris)] =
        SpaceCatalog.all.filter { $0.horizons != nil }.map { ($0, SpaceEphemeris()) }

    /// One at a time, as JPL asks of scripts, and each kept for a day.
    private func loadSpacecraftPositions() async {
        for (object, ephemeris) in spaceEphemerides {
            if let track = await Horizons.positions(of: object) { ephemeris.set(track) }
        }
        positionsVersion += 1
    }

    /// The names SatNOGS knows a satellite by, so people can search for what they call it.
    private func loadOtherNames() async {
        guard let data = try? await DataFetcher.data("https://db.satnogs.org/api/satellites/?format=json", cacheName: "satnogs_satellites.json",
                                                     maxAge: 86400, userAgent: AMSATAPI.userAgent) else { return }
        let aliases = satnogsAliases
        let table = await Task.detached(priority: .utility) { () -> [Int: [String]] in
            struct Row: Decodable { let norad_cat_id: Int?; let name: String?; let names: String? }
            guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [:] }
            var out: [Int: [String]] = [:]
            for row in rows {
                guard let n = row.norad_cat_id else { continue }
                out[n, default: []] += SatelliteRegistry.otherNames(name: row.name, names: row.names)
                if let real = aliases[n] { out[real, default: []] += SatelliteRegistry.otherNames(name: row.name, names: row.names) }
            }
            return out
        }.value
        for s in satellites { s.otherNames = table[s.norad] ?? [] }
    }

    /// AMSAT's index, plus the few spacecraft downlinks that are well documented.
    private func loadFrequencyIndex() async {
        var table: [Int: [Transmitter]] = [:]
        if let data = try? await DataFetcher.data(AMSATFrequencyIndex.url, cacheName: "amsat_frequencies.json", maxAge: 86400, userAgent: AMSATAPI.userAgent) {
            let rows = await Task.detached(priority: .utility) { (try? JSONDecoder().decode([AMSATFrequencyIndex.Row].self, from: data)) ?? [] }.value
            indexRows = rows
            table = await Task.detached(priority: .utility) { () -> [Int: [Transmitter]] in
                var out: [Int: [Transmitter]] = [:]
                for row in rows {
                    guard let n = row.norad_id.flatMap({ Int($0) }) else { continue }
                    out[n, default: []] += AMSATFrequencyIndex.transmitters(row)
                }
                return out
            }.value
        }
        for s in satellites {
            // Specific listings come first, so a published band only fills in where nothing better is known.
            let extra = (table[s.norad] ?? []) + (s.spaceObject.flatMap { SpaceCatalog.downlinks[$0.name] } ?? [])
                + ConstellationBands.transmitters(forName: s.name)
            guard !extra.isEmpty else { continue }
            s.transmitters = AMSATFrequencyIndex.merge(s.transmitters, with: extra)
            s.media = MediaSignal.signals(in: s.transmitters)
        }
    }

    /// Who runs it, who built it, and what it weighs. These files are large and change slowly.
    private func loadRegistry() async {
        let agent = AMSATAPI.userAgent
        guard let catalogue = try? await DataFetcher.data(SatelliteRegistry.catalogueURL, cacheName: "gcat_satcat.tsv", maxAge: 7 * 86400, userAgent: agent) else { return }
        let payloads = try? await DataFetcher.data(SatelliteRegistry.payloadsURL, cacheName: "gcat_psatcat.tsv", maxAge: 7 * 86400, userAgent: agent)
        let organisations = try? await DataFetcher.data(SatelliteRegistry.organisationsURL, cacheName: "gcat_orgs.tsv", maxAge: 30 * 86400, userAgent: agent)
        let wanted = Set(satellites.map(\.norad))
        var designators: [String: Int] = [:]
        for s in satellites where !s.objectID.isEmpty { designators[s.objectID] = s.norad }
        let lookup = designators
        let entries = await Task.detached(priority: .utility) { () -> [Int: RegistryEntry] in
            func text(_ d: Data?) -> String? { d.map { String(decoding: $0, as: UTF8.self) } }
            return SatelliteRegistry.parse(catalogue: text(catalogue) ?? "", payloads: text(payloads),
                                           organisations: SatelliteRegistry.organisations(text(organisations) ?? ""), wanted: wanted, designators: lookup)
        }.value
        for s in satellites { s.registry = entries[s.norad] }
    }


    /// How old the orbit data for this satellite is, by when it was measured rather than downloaded.
    func oldestLockedEpochDays(_ sat: Satellite?) -> Double? {
        sat.map { Astro.julianDate() - $0.epochJD }
    }

    /// Adds satellites reported as transmitting that the main list leaves out. On its own step,
    /// so a slow answer can't hold up the globe.
    private var satnogsAliases: [Int: Int] = [:]

    /// Needs the satellites list, and only runs once the catalogue is loaded to match it against.
    private func loadSatNOGSAliases() async {
        guard let data = try? await DataFetcher.data("https://db.satnogs.org/api/satellites/?format=json", cacheName: "satnogs_satellites.json",
                                                     maxAge: 86400, userAgent: AMSATAPI.userAgent) else { return }
        let catalog = satellites.filter { !$0.fromSatNOGS }.map { (norad: $0.norad, name: $0.name) }
        satnogsAliases = await Task.detached(priority: .utility) {
            SatNOGSIdentity.aliases((try? JSONDecoder().decode([SatNOGSIdentity.Row].self, from: data)) ?? [], catalog: catalog)
        }.value
    }

    private func addReportedSatellites() async {
        await loadSatNOGSAliases()
        var transmitting = Set<Int>()
        struct ListedRow: Decodable { let norad_cat_id: Int?; let status: String?; let alive: Bool? }
        if let data = try? await DataFetcher.data("https://db.satnogs.org/api/transmitters/?format=json", cacheName: "satnogs_transmitters.json", maxAge: 86400),
           let rows = try? JSONDecoder().decode([ListedRow].self, from: data) {
            for r in rows where r.status == "active" && r.alive != false { if let n = r.norad_cat_id { transmitting.insert(n) } }
        }
        if let data = try? await DataFetcher.data(AMSATFrequencyIndex.url, cacheName: "amsat_frequencies.json", maxAge: 86400, userAgent: AMSATAPI.userAgent),
           let rows = try? JSONDecoder().decode([AMSATFrequencyIndex.Row].self, from: data) {
            for r in rows where r.status?.lowercased() == "active" { if let n = r.norad_id.flatMap({ Int($0) }) { transmitting.insert(n) } }
        }
        guard !transmitting.isEmpty,
              let data = try? await DataFetcher.data(ExtraSatellites.url, cacheName: "satnogs_tle.json", maxAge: 6 * 3600, userAgent: AMSATAPI.userAgent,
                                                     authorization: SatNOGSKey.load().map { "Token \($0)" }),
              let rows = try? JSONDecoder().decode([ExtraSatellites.Row].self, from: data) else { return }
        // Not again under its temporary number, when it's already here under its real one.
        let known = Set(satellites.map(\.norad)).union(satnogsAliases.keys)
        let jd = Astro.julianDate()
        let extras = ExtraSatellites.select(rows, transmitting: transmitting, known: known, now: Date()).compactMap { omm -> Satellite? in
            // Not one whose orbit has already run out, nor spent rocket stages and debris.
            let upper = omm.OBJECT_NAME.uppercased()
            guard !upper.contains(" R/B"), !upper.contains(" DEB"), let s = Satellite(omm: omm), s.state(jd: jd) != nil, !s.isDecayEstimate else { return nil }
            s.fromSatNOGS = true
            s.category = NameRules.category(for: s.name)
            return s
        }
        guard !extras.isEmpty else { return }
        satellites += extras
        for s in extras { byNorad[s.norad] = s }
        classCounts = satellites.reduce(into: [:]) { $0[$1.orbit, default: 0] += 1 }
        catalogVersion += 1
    }

    func load() async {
        if satellites.isEmpty { status = "Loading satellites…" }
        do {
            // CelesTrak updates GP data every two hours and asks clients not to fetch faster.
            let data = try await DataFetcher.preferCached(
                "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=json",
                cacheName: "gp_active.json", refreshAfter: 7200, usableFor: 3 * 86400)
            // Kept across reloads, so spacecraft don't vanish while new positions arrive.
            let spacecraft = spaceEphemerides
            let sats = try await Task.detached(priority: .userInitiated) { () -> [Satellite] in
                let omm = try JSONDecoder().decode([OMM].self, from: data)
                // Those JPL places better are left to it: these orbits often don't track them.
                let far = Set(SpaceCatalog.all.filter { $0.horizons != nil }.map(\.noradID))
                let fromOrbits = omm.compactMap { far.contains($0.NORAD_CAT_ID) ? nil : Satellite(omm: $0) }
                return fromOrbits + spacecraft.map { Satellite(space: $0.object, ephemeris: $0.ephemeris) }
            }.value
            classCounts = sats.reduce(into: [:]) { $0[$1.orbit, default: 0] += 1 }
            satellites = sats
            catalogVersion += 1
            byNorad = Dictionary(sats.map { ($0.norad, $0) }, uniquingKeysWith: { a, _ in a })
            for s in sats { s.category = NameRules.category(for: s.name) }
            lastUpdate = Date()
            status = "\(sats.count.formatted()) satellites"
        } catch {
            status = "Could not load satellites: \(error.localizedDescription)"
            return
        }
        await addReportedSatellites()
        // Each catalogue is independent: a failure in one must not take down the others.
        async let a: Void = loadSatcat()
        async let b: Void = loadTransmitters()
        async let amsat: Void = loadAMSATMedia()
        async let c: Void = loadGroups()
        _ = await (a, b, amsat, c)
        await loadJE9PEL()
        // Each needs the catalogue above to add to. Positions go last, as they take longest.
        async let frequencies: Void = loadFrequencyIndex()
        async let registry: Void = loadRegistry()
        async let names: Void = loadOtherNames()
        _ = await (frequencies, registry, names)
        linkStationParts()
        linkListedTalkThrough()
        for s in satellites where s.spaceObject != nil { s.category = .research }
        enrichmentVersion += 1
        reapplyFilter()
        Task { await loadSpacecraftPositions() }
        Task { _ = await SatNOGSDecoderFiles.update() }
    }

    /// Space station modules and docked vehicles have no radio entries of their own, but they're
    /// physically part of the station, so its frequencies apply. A vehicle counts only while it's
    /// actually at the station: one flying free has its own radios, which aren't public.
    /// Everything listed with an uplink counts here, including what the transmit rules wouldn't allow,
    /// as this is only about finding them. AMSAT lists many that SatNOGS doesn't, some with no NORAD number.
    private func linkListedTalkThrough() {
        var byNorad: [Int: Satellite] = [:]
        var byName: [String: Satellite] = [:]
        for s in satellites {
            byNorad[s.norad] = s
            for name in [s.name] + s.otherNames {
                for key in AMSATFrequencyIndex.nameKeys(name) where byName[key] == nil { byName[key] = s }
            }
        }
        var working = Set<Int>()
        func add(_ kinds: Set<CommunicationKind>, to s: Satellite, active: Bool) {
            guard !kinds.isEmpty else { return }
            s.communication.formUnion(kinds)
            if active { working.insert(s.norad) }
        }
        for s in satellites {
            for t in s.transmitters where t.uplinkLowHz != nil {
                add(CommunicationKind.listed(mode: t.uplinkMode ?? t.mode), to: s, active: t.active)
            }
        }
        for row in indexRows {
            let kinds = row.talkThrough
            guard !kinds.isEmpty else { continue }
            let number = row.norad_id.flatMap { Int($0) }
            guard let s = number.flatMap({ byNorad[$0] }) ?? row.name.flatMap({ AMSATFrequencyIndex.nameKeys($0).compactMap { byName[$0] }.first }) else { continue }
            add(kinds, to: s, active: row.isActive)
        }
        // What it's licensed for says what it is, when nothing else has.
        for s in satellites where s.category == .unknown && s.transmitters.contains(where: { $0.active && $0.service == "Amateur" }) {
            s.category = .amateur
        }
        for s in satellites { s.talkThroughListedInactive = !s.communication.isEmpty && !working.contains(s.norad) }
        reapplyFilter()
    }

    private func linkStationParts() {
        let visiting = #"^(SOYUZ|PROGRESS|DRAGON|CREW DRAGON|CYGNUS|SHENZHOU|TIANZHOU|HTV|STARLINER|DREAM CHASER)"#
        let jd = Astro.julianDate()
        for (norad, label, module) in [(25544, "ISS", #"^(ISS \(|POISK|PIRS|RASSVET|PRICHAL)"#), (48274, "CSS", #"^CSS \("#)] {
            guard let parent = byNorad[norad], !parent.transmitters.isEmpty, let here = parent.clone()?.state(jd: jd)?.r else { continue }
            for s in satellites where s.norad != norad {
                let name = s.name.uppercased()
                let isModule = name.range(of: module, options: .regularExpression) != nil
                let isVehicle = name.range(of: visiting, options: .regularExpression) != nil
                guard isModule || isVehicle, let there = s.clone()?.state(jd: jd)?.r, simd_distance(here, there) < 25 else { continue }
                // The station's main radios first, then anything listed for this part alone.
                s.transmitters = parent.transmitters + s.transmitters
                s.sharedWith = isVehicle ? "Docked at the \(label)" : "Part of the \(label)"
                s.category = .station
            }
        }
    }

    private func loadSatcat() async {
        guard let data = try? await DataFetcher.data("https://celestrak.org/pub/satcat.csv",
                                                     cacheName: "satcat.csv", maxAge: 7 * 86400) else { return }
        let owners = await Task.detached(priority: .utility) { () -> [Int: String] in
            var out: [Int: String] = [:]
            guard let text = String(data: data, encoding: .utf8) else { return out }
            // CelesTrak's CSV uses CRLF, which Swift treats as one Character, so "\n" would never match.
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                if f.count > 5, let n = Int(f[2]) { out[n] = String(f[5]) }
            }
            return out
        }.value
        for s in satellites { s.ownerCode = owners[s.norad] ?? "" }
        enrichmentVersion += 1
    }

    private struct SatNOGSTx: Decodable {
        let description: String?
        let downlink_low: Double?
        let mode: String?
        let status: String?
        let alive: Bool?
        let norad_cat_id: Int?
        let norad_follow_id: Int?
        let baud: Double?
        let downlink_high: Double?
        let uplink_low: Double?
        let uplink_high: Double?
        let uplink_mode: String?
        let invert: Bool?
        let service: String?
        let type: String?
        let iaru_coordination: String?
        let frequency_violation: Bool?
    }

    /// The picture modes AMSAT tracks. The same daily copy the Transmit page uses.
    private func loadAMSATMedia() async {
        guard let data = try? await DataFetcher.data(AMSATAPI.base + "/catalog.php", cacheName: "amsat_catalog.json", maxAge: 86400,
                                                     userAgent: AMSATAPI.userAgent),
              let list = try? JSONDecoder().decode(AMSATAPI.List<AMSATAPI.CatalogEntry>.self, from: data).data else { return }
        var byName: [String: Set<MediaKind>] = [:]
        for entry in list {
            if let kind = MediaKind.fromAMSATMode(entry.name) { byName[AMSATAPI.baseName(entry.name).uppercased(), default: []].insert(kind) }
        }
        guard !byName.isEmpty else { return }
        for s in satellites {
            let kinds = AMSATAPI.candidates(name: s.name, norad: s.norad).compactMap { byName[$0] }
            s.amsatMedia = kinds.reduce(into: []) { $0.formUnion($1) }
        }
        enrichmentVersion += 1
        reapplyFilter()
    }

    private func loadTransmitters() async {
        guard let data = try? await DataFetcher.data("https://db.satnogs.org/api/transmitters/?format=json",
                                                     cacheName: "satnogs_transmitters.json", maxAge: 86400) else { return }
        var table = await Task.detached(priority: .utility) { () -> [Int: [Transmitter]] in
            guard let list = try? JSONDecoder().decode([SatNOGSTx].self, from: data) else { return [:] }
            var out: [Int: [Transmitter]] = [:]
            for t in list {
                guard let n = t.norad_cat_id, let f = t.downlink_low, f > 0 else { continue }
                let entry = (Transmitter(
                    description: t.description ?? "Downlink", downlinkHz: f, mode: t.mode ?? "?",
                    active: t.status == "active" && (t.alive ?? true), baud: t.baud,
                    downlinkHighHz: t.downlink_high, uplinkLowHz: t.uplink_low, uplinkHighHz: t.uplink_high,
                    uplinkMode: t.uplink_mode, inverted: t.invert ?? false, service: t.service ?? "",
                    kind: t.type ?? "", coordination: t.iaru_coordination ?? "",
                    frequencyViolation: t.frequency_violation ?? false))
                out[n, default: []].append(entry)
                // New satellites are filed under a temporary number with their real one alongside.
                if let real = t.norad_follow_id, real != n { out[real, default: []].append(entry) }
            }
            return out
        }.value
        var numbers: [Int: Int] = [:]
        for (theirs, ours) in satnogsAliases {
            numbers[ours] = theirs
            for t in table[theirs] ?? [] where !(table[ours] ?? []).contains(t) { table[ours, default: []].append(t) }
        }
        for s in satellites {
            s.satnogsNumber = numbers[s.norad]
            s.transmitters = table[s.norad] ?? []
            s.communication = CommunicationKind.of(norad: s.norad, uplinks: UplinkPolicy.listedUplinks(for: s))
            s.media = MediaSignal.signals(in: s.transmitters)
        }
        reapplyFilter()
        enrichmentVersion += 1
    }

    private func loadGroups() async {
        // CelesTrak's curated groups beat name matching. Sequential, and cached for a week, to stay polite.
        let groups: [(String, SatCategory)] = [
            ("cubesat", .education), ("education", .education), ("engineering", .technology),
            ("amateur", .amateur), ("resource", .earthObservation), ("science", .research),
            ("geodetic", .research), ("geo", .communications), ("gnss", .navigation),
            ("weather", .weather), ("military", .military), ("stations", .station),
        ]
        for (group, category) in groups {
            guard let data = try? await DataFetcher.data(
                "https://celestrak.org/NORAD/elements/gp.php?GROUP=\(group)&FORMAT=csv",
                cacheName: "group_\(group).csv", maxAge: 7 * 86400),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: \.isNewline)
            guard let header = lines.first?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                  let col = header.firstIndex(of: "NORAD_CAT_ID") else { continue }
            for line in lines.dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                if f.count > col, let n = Int(f[col]), let s = byNorad[n] {
                    // `geo` is a location rather than a mission, so it must not overwrite a name match.
                    if group == "geo", s.category != .unknown { continue }
                    s.category = category
                }
            }
        }
        enrichmentVersion += 1
    }
}

enum NameRules {
    private static let rules: [(SatCategory, [String])] = [
        (.station, ["ISS (", "CSS (", "TIANGONG", "TIANHE", "WENTIAN", "MENGTIAN", "NAUKA", "ZARYA"]),
        (.military, ["USA ", "USA-", "NROL", "COSMOS", "KOSMOS", "YAOGAN", "SBIRS", "MUOS", "WGS ", "AEHF", "MILSTAR", "DSP ", "SKYNET", "SICRAL", "SYRACUSE", "WSF-M", "DMSP", "OFEQ", "GSSAP", "LUCH"]),
        (.weather, ["NOAA", "GOES", "METOP", "METEOR", "METEOSAT", "FENGYUN", "FY-", "HIMAWARI", "GK-2", "GEO-KOMPSAT", "ELEKTRO", "INSAT", "AWS"]),
        (.navigation, ["GPS", "NAVSTAR", "GALILEO", "GSAT0", "BEIDOU", "GLONASS", "QZS", "IRNSS", "NAVIC"]),
        (.communications, ["STARLINK", "ONEWEB", "KUIPER", "IRIDIUM", "GLOBALSTAR", "ORBCOMM", "INTELSAT", "SES", "EUTELSAT", "ASTRA", "INMARSAT", "VIASAT", "TELSTAR", "THOR", "TURKSAT", "GALAXY", "O3B", "QIANFAN", "GUOWANG", "SPACEMOBILE", "ECHOSTAR", "DIRECTV", "ARABSAT"]),
        (.earthObservation, ["LANDSAT", "SENTINEL", "TERRA", "AQUA", "AURA", "SPOT", "PLEIADES", "WORLDVIEW", "FLOCK", "LEMUR", "ICEYE", "CAPELLA", "RESURS", "KANOPUS", "JILIN", "GAOFEN", "CARTOSAT", "SKYSAT"]),
        (.research, ["HST", "HUBBLE", "CXO", "CHANDRA", "XMM", "SWIFT", "FERMI", "TESS", "JWST", "IXPE", "NUSTAR", "DSCOVR", "STEREO", "SOHO", "ACE", "WIND", "CHEOPS", "THEMIS"]),
    ]

    static func category(for name: String) -> SatCategory {
        let u = name.uppercased()
        for (category, prefixes) in rules where prefixes.contains(where: { u.hasPrefix($0) }) { return category }
        return .unknown
    }
}
