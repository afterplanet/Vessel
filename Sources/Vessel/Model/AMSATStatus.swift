import Foundation

/// AMSAT's live satellite status, from operators reporting what they heard.
/// https://status.amsat.org/api/v1/overview.php asks clients to name themselves, poll no more
/// often than every 5 minutes, credit AMSAT, and only submit when the operator chooses to.
enum AMSATAPI {
    static let base = "https://status.amsat.org/api/v1"
    static let site = URL(string: "https://status.amsat.org")!
    static let userAgent = "Vessel/1.0 (+https://github.com/afterplanet/Vessel)"
    static let pollSeconds: TimeInterval = 300
    /// After a failed refresh, as they ask: back off rather than retrying at the usual pace.
    static let backoffSeconds: TimeInterval = 900

    struct CatalogEntry: Decodable, Equatable {
        let name: String
        let display_name: String
    }

    struct SummaryRow: Decodable, Equatable {
        let name: String
        let satellite_display_name: String?
        let report: String
        let report_count: Int
        let latest_reported_time: String
    }

    struct Report: Decodable, Equatable, Identifiable {
        let id: Int
        let name: String
        let reported_time: String
        let callsign: String
        let report: String
        let grid_square: String?
        var date: Date? { AMSATAPI.date(reported_time) }
    }

    struct List<T: Decodable>: Decodable { let data: [T] }

    private static let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func date(_ s: String) -> Date? { dates.date(from: s) }

    static func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? s
    }

    /// Where a satellite's name doesn't lead to its AMSAT name. Each checked against the catalogue's object name.
    private static let byNorad: [Int: String] = [
        25544: "ISS",     // ISS (ZARYA)
        43017: "AO-91",   // RADFXSAT (FOX-1B)
        43678: "PO-101",  // DIWATA-2B
        43700: "QO-100",  // ES'HAIL 2
        44881: "TO-108",  // TIANYAN 01
        40908: "CAS-3H",  // LILACSAT-2
        68795: "FO-126",  // ORIGAMISAT-2
    ]

    /// "SO-50_[FM]" is the FM mode of "SO-50".
    static func baseName(_ name: String) -> String {
        name.components(separatedBy: "_[").first ?? name
    }

    /// The names AMSAT could use for a satellite: its whole name, the designator in brackets, or the
    /// part before them. "SAUDISAT 1C (SO-50)", "LUCA (RS90S)", "RS-44 & BREEZE-KM R/B".
    static func candidates(name: String, norad: Int) -> Set<String> {
        var out = Set<String>()
        if let known = byNorad[norad] { out.insert(known.uppercased()) }
        let upper = name.uppercased()
        out.insert(upper)
        var rest = upper
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            out.insert(String(rest[rest.index(after: open)..<close]))
            rest = String(rest[rest.index(after: close)...])
        }
        for separator in [" (", " & "] {
            if let head = upper.components(separatedBy: separator).first { out.insert(head) }
        }
        // Each module of the station is catalogued as "ISS (…)", but the radio is only tracked as the ISS itself.
        if norad != 25544 { out.remove("ISS") }
        return out
    }

    /// One mode of a satellite, as the last day's reports describe it.
    struct ModeStatus: Identifiable, Equatable {
        let name: String
        let display: String
        var counts: [String: Int] = [:]
        var latest: Date?
        var latestReport: String?
        var id: String { name }
        var total: Int { counts.values.reduce(0, +) }
    }

    /// Most recently reported first. Modes with no reports stay listed, since that's worth knowing too.
    static func modes(for name: String, norad: Int, catalog: [CatalogEntry], summary: [SummaryRow]) -> [ModeStatus] {
        let wanted = candidates(name: name, norad: norad)
        let entries = catalog.filter { wanted.contains(baseName($0.name).uppercased()) }
        return entries.map { entry in
            var mode = ModeStatus(name: entry.name, display: entry.display_name)
            for row in summary where row.name == entry.name {
                mode.counts[row.report, default: 0] += row.report_count
                if let d = date(row.latest_reported_time), d > (mode.latest ?? .distantPast) {
                    mode.latest = d
                    mode.latestReport = row.report
                }
            }
            return mode
        }
        .sorted { a, b in
            if (a.latest ?? .distantPast) != (b.latest ?? .distantPast) { return (a.latest ?? .distantPast) > (b.latest ?? .distantPast) }
            return a.name < b.name
        }
    }

    enum Observation: String, CaseIterable, Identifiable {
        case heard = "Heard", telemetry = "Telemetry Only", notHeard = "Not Heard"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .heard: "Active"
            case .telemetry: "Beacon only"
            case .notHeard: "Not heard"
            }
        }
    }

    /// Every report must be a real observation by the callsign it carries, so this is only ever
    /// built from the operator pressing submit. An SSID identifies a station, not the operator.
    static func submission(name: String, observation: Observation, callsign: String, grid: String?, at: Date) -> URLRequest? {
        guard let url = URL(string: base + "/reports.php"), let call = callsign.split(separator: "-").first else { return nil }
        var body: [String: String] = ["name": name, "report": observation.rawValue, "callsign": String(call), "reported_at": dates.string(from: at)]
        if let grid { body["grid_square"] = grid }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.httpBody = data
        return r
    }

    struct Submitted: Decodable {
        struct Inner: Decodable { let correction: Bool? }
        let data: Inner
    }
    struct Failure: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner
    }
}

@MainActor
final class AMSATStatus: ObservableObject {
    @Published private(set) var modes: [AMSATAPI.ModeStatus] = []
    @Published private(set) var recent: [AMSATAPI.Report] = []
    @Published private(set) var updated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    @Published private(set) var sending = false
    @Published var sentMessage: String?

    private static func fetch(_ path: String, cache: String, maxAge: TimeInterval) async -> Data? {
        try? await DataFetcher.data(AMSATAPI.base + path, cacheName: cache, maxAge: maxAge, userAgent: AMSATAPI.userAgent)
    }

    private static func cacheName(_ name: String) -> String {
        "amsat_reports_" + name.replacingOccurrences(of: "[^A-Za-z0-9-]+", with: "_", options: .regularExpression) + ".json"
    }

    /// Returns how long to wait before the next look.
    @discardableResult
    func refresh(name: String, norad: Int, freshReports: Bool = false) async -> TimeInterval {
        isLoading = true
        defer { isLoading = false }
        // The catalogue barely changes, and one summary covers every satellite.
        async let catalogData = Self.fetch("/catalog.php", cache: "amsat_catalog.json", maxAge: 86400)
        async let summaryData = Self.fetch("/summary.php?hours=24", cache: "amsat_summary.json", maxAge: AMSATAPI.pollSeconds)
        let (c, s) = await (catalogData, summaryData)
        if Task.isCancelled { return AMSATAPI.pollSeconds }
        let decoder = JSONDecoder()
        let catalog = c.flatMap { try? decoder.decode(AMSATAPI.List<AMSATAPI.CatalogEntry>.self, from: $0).data } ?? []
        let summary = s.flatMap { try? decoder.decode(AMSATAPI.List<AMSATAPI.SummaryRow>.self, from: $0).data }
        modes = AMSATAPI.modes(for: name, norad: norad, catalog: catalog, summary: summary ?? [])

        let file = Res.cacheDir.appendingPathComponent("amsat_summary.json")
        updated = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        // A failed fetch falls back on the saved copy, which shows up as one that's out of date.
        failed = summary == nil || Date().timeIntervalSince(updated ?? .distantPast) > AMSATAPI.pollSeconds + 60

        var reports: [AMSATAPI.Report] = []
        let reported = modes.filter { $0.total > 0 }.prefix(3)
        for mode in reported {
            let path = "/reports.php?name=\(AMSATAPI.query(mode.name))&hours=24&limit=5"
            if let d = await Self.fetch(path, cache: Self.cacheName(mode.name), maxAge: freshReports ? 0 : AMSATAPI.pollSeconds),
               let list = try? decoder.decode(AMSATAPI.List<AMSATAPI.Report>.self, from: d) {
                reports += list.data
            }
        }
        if Task.isCancelled { return AMSATAPI.pollSeconds }
        recent = Array(reports.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(5))
        return failed ? AMSATAPI.backoffSeconds : AMSATAPI.pollSeconds
    }

    /// The operator pressed submit and confirmed exactly what's being sent.
    func submit(mode: AMSATAPI.ModeStatus, observation: AMSATAPI.Observation, callsign: String, grid: String?,
                satellite: String, norad: Int) async {
        guard let request = AMSATAPI.submission(name: mode.name, observation: observation, callsign: callsign, grid: grid, at: Date()) else { return }
        sending = true
        defer { sending = false }
        do {
            let (data, response) = try await DataFetcher.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 201 {
                let corrected = (try? JSONDecoder().decode(AMSATAPI.Submitted.self, from: data))?.data.correction == true
                sentMessage = corrected ? "Sent. It replaces your earlier report for this 15 minutes." : "Sent to AMSAT. Thanks for reporting."
                await refresh(name: satellite, norad: norad, freshReports: true)
            } else {
                let why = (try? JSONDecoder().decode(AMSATAPI.Failure.self, from: data))?.error.message
                sentMessage = "AMSAT didn't accept it: \(why ?? "error \(code)")"
            }
        } catch {
            sentMessage = "Couldn't reach AMSAT, so nothing was sent."
        }
    }
}
