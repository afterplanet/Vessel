import Foundation
import SceneKit
import SwiftUI

/// A published 3D model, and how closely it matches the satellite it's shown for.
struct ModelChoice: Equatable, Hashable {
    enum Match { case exact, family, standIn }
    /// Path inside NASA's 3D Resources collection, under "3D Models".
    let path: String
    /// What the model actually depicts.
    let title: String
    let match: Match
    /// Start of the names of stray parts left in a published file, which shouldn't be shown.
    var hidden: [String] = []
    /// For tests: a path on disk.
    var local = false
    /// Shipped with the app under this name. NASA's models are fetched instead.
    var bundled: String? = nil
    /// Who made a community model. Their licence asks for this to be shown.
    var credit: String? = nil

    var caption: String {
        let maker = credit ?? "NASA"
        switch match {
        case .exact: return "\(title), 3D model by \(maker)"
        case .family: return "\(title), same design family. 3D model by \(maker)"
        case .standIn: return "Stand-in: \(title), a similar type. 3D model by \(maker)"
        }
    }

    /// Pinned to one commit, so a model can't change or vanish under a released app.
    static let commit = "11ebb4ee043715aefbba6aeec8a61746fad67fa7"

    var url: URL? {
        let full = "3D Models/\(path).glb"
        guard let escaped = full.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "+,"))) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/nasa/NASA-3D-Resources/\(Self.commit)/\(escaped)")
    }
}

enum ModelCatalog {
    private static func m(_ folder: String, _ title: String, _ match: ModelChoice.Match = .exact, hidden: [String] = []) -> ModelChoice {
        ModelChoice(path: "\(folder)/\(folder)", title: title, match: match, hidden: hidden)
    }

    private static func community(_ file: String, _ title: String, _ match: ModelChoice.Match, by credit: String) -> ModelChoice {
        ModelChoice(path: "community/\(file)", title: title, match: match, bundled: "\(file).glb", credit: credit)
    }

    private static let starlink = (file: "starlink", title: "a Starlink satellite", by: "Malacodart, CC BY 4.0")
    private static let tiangong = (file: "tiangong", title: "the Tiangong space station", by: "w29572227, CC BY 4.0")
    private static let typical = (file: "simple_djalal", title: "a typical satellite", by: "DjalalxJay, CC BY 4.0")

    /// Most specific first. Patterns match the catalogue's names for real objects.
    static let rules: [(pattern: String, choice: ModelChoice)] = [
        ("^STARLINK", community(starlink.file, starlink.title, .exact, by: starlink.by)),
        ("^CSS \\(", community(tiangong.file, tiangong.title, .exact, by: tiangong.by)),
        ("^ISS \\(", m("International Space Station (ISS) (B)", "the ISS", hidden: ["bendedtru", "pCylinder"])),
        ("^HST$", m("Hubble Space Telescope (A)", "the Hubble Space Telescope")),
        ("^James Webb", m("James Webb Space Telescope (A)", "the James Webb Space Telescope")),
        ("^Lunar Reconnaissance", m("Lunar Reconnaissance Orbiter (A)", "the Lunar Reconnaissance Orbiter")),
        ("^Mars Reconnaissance", m("Mars Reconnaissance Orbiter (MRO) (A)", "the Mars Reconnaissance Orbiter")),
        ("^Mars Odyssey", m("Mars Odyssey", "Mars Odyssey")),
        ("^Curiosity", m("Curiosity Rover (MSL)", "the Curiosity rover")),
        ("^Juno", m("Juno (A)", "Juno")),
        ("^Parker Solar", m("Parker Solar Probe", "Parker Solar Probe")),
        ("^SOHO", m("Solar and Heliospheric Observatory", "SOHO")),
        ("^DSCOVR", m("Deep Space Climate Observatory (DSCOVR) (Triana)", "DSCOVR")),
        ("^Voyager", m("Voyager Probe (A)", "a Voyager probe")),
        ("^TESS", m("Transiting Exoplanet Survey Satellite (TESS) (A)", "TESS")),
        ("^OSIRIS", m("Origins, Spectral Interpretation, Resource Identification, and Security - Regolith Explorer (OSIRIS-REx)", "OSIRIS-REx")),
        ("^CXO$", m("Chandra X-ray Observatory", "Chandra")),
        ("^AQUA$", m("Aqua (A)", "Aqua")),
        ("^TERRA$", m("Terra", "Terra")),
        ("^AURA$", m("Aura (B)", "Aura")),
        ("^LANDSAT 8$", m("Landsat 8", "Landsat 8")),
        ("^LANDSAT 9$", m("Landsat 8", "Landsat 8", .family)),
        ("^ICESAT-2$", m("Ice, Clouds, and Land Elevation Satellite-2 (ICESat-2) (B)", "ICESat-2")),
        ("^SENTINEL-6", m("Jason Continuity of Service (Sentinel-6)", "Sentinel-6")),
        ("^JASON", m("Ocean Surface Topography Mission (OSTM Jason-2)", "Jason-2", .family)),
        ("^OCO 2$", m("Orbiting Carbon Observatory (OCO) 2", "OCO-2")),
        ("^SDO$", m("Solar Dynamics Observatory", "the Solar Dynamics Observatory")),
        ("^SWIFT$", m("Swift", "Swift")),
        ("^GLAST|^FERMI", m("Fermi Gamma-ray Large Area Space Telescope", "Fermi")),
        ("^GRACE-FO", m("Gravity Recovery and Climate Experiment (GRACE) (B)", "GRACE", .family)),
        ("^GPM", m("Global Precipitation Measurement", "GPM Core")),
        ("^CYGFM", m("Cyclone Global Navigation Satellite System (CYGNSS)", "CYGNSS")),
        ("^THEMIS", m("Time History of Events and Macroscale Interactions During Substorms (THEMIS)", "THEMIS")),
        ("^MMS [1-4]$", m("Magnetospheric Multiscale (MMS) (B)", "MMS")),
        ("^HINODE", m("Hinode (Solar-B)", "Hinode")),
        ("^SORCE$", m("Solar Radiation and Climate Experiment (SORCE)", "SORCE")),
        ("^SWAS$", m("Submillimeter Wave Astronomy Satellite (SWAS)", "SWAS")),
        ("^POLAR$", m("Polar", "Polar")),
        ("^TDRS", m("Tracking and Data Relay Satellites (TDRS) (D)", "TDRS")),
        ("GOES", m("Geostationary Operational Environmental Satellites", "GOES")),
        ("^SUOMI NPP$", m("Suomi National Polar-orbiting Partnership (Suomi NPP)", "Suomi NPP")),
        ("^NOAA (20|21)", m("Suomi National Polar-orbiting Partnership (Suomi NPP)", "Suomi NPP", .family)),
        ("^NOAA ", m("Polar Operational Environmental Satellite (POES)", "POES")),
        ("^RADARSAT", m("Radar Satellite-1 (RADARSAT-1)", "RADARSAT-1", .family)),
        // Shoebox imagers, which would otherwise count as big weather platforms by mission.
        ("^(FLOCK|LEMUR|SPIRE|CUBESAT|DOVE)", m("CubeSat - MiRaTa", "MiRaTa CubeSat", .standIn)),
    ]

    /// By class, when nothing more specific exists. These are always labelled as stand-ins.
    static func choice(forName name: String, kind: SatelliteModel.Kind) -> ModelChoice {
        for rule in rules where name.range(of: rule.pattern, options: .regularExpression) != nil { return rule.choice }
        switch kind {
        case .station: return community(tiangong.file, tiangong.title, .standIn, by: tiangong.by)
        case .flatPanel: return community(starlink.file, starlink.title, .standIn, by: starlink.by)
        case .comsat: return m("Space Systems Loral (SSL-1300)", "an SSL-1300 comsat", .standIn)
        case .weather: return m("Polar Operational Environmental Satellite (POES)", "a POES weather satellite", .standIn)
        case .cubesat: return m("CubeSat - MiRaTa", "the MiRaTa CubeSat", .standIn)
        case .observatory: return m("Chandra X-ray Observatory", "the Chandra observatory", .standIn)
        case .recon: return m("Hubble Space Telescope (A)", "Hubble, a large telescope bus", .standIn)
        case .navigation, .generic: return community(typical.file, typical.title, .standIn, by: typical.by)
        }
    }

    static func choice(for s: Satellite) -> ModelChoice { choice(forName: s.name, kind: SatelliteModel.kind(for: s)) }
}

/// Fetches a model once, keeps it on disk, and hands back a fresh copy for each scene.
@MainActor
final class SatelliteModelLoader: ObservableObject {
    enum State: Equatable { case none, loading, ready, failed }

    @Published private(set) var state = State.none
    @Published private(set) var node: SCNNode?
    @Published private(set) var choice: ModelChoice?

    private static var memory: [String: SCNNode] = [:]
    private static var order: [String] = []
    private var task: Task<Void, Never>?

    /// Largest download accepted. The biggest model in the catalogue is under 10 MB.
    static let maxBytes = 40_000_000

    static var directory: URL {
        let dir = Res.cacheDir.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load(_ choice: ModelChoice?) {
        guard choice != self.choice || state == .failed else { return }
        task?.cancel()
        self.choice = choice
        node = nil
        guard let choice else { state = .none; return }
        state = .loading
        task = Task { [weak self] in
            let loaded = await Self.fetch(choice)
            guard !Task.isCancelled else { return }
            self?.node = loaded
            self?.state = loaded == nil ? .failed : .ready
        }
    }

    static func fetch(_ choice: ModelChoice) async -> SCNNode? {
        if let hit = memory[choice.path] { return hit.clone() }
        let name = choice.path.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression) + ".glb"
        let file = directory.appendingPathComponent(name)
        var data: Data?
        if choice.local {
            data = try? Data(contentsOf: URL(fileURLWithPath: choice.path))
        } else if let bundled = choice.bundled {
            data = Res.url("models/\(bundled)").flatMap { try? Data(contentsOf: $0) }
        } else {
            data = try? Data(contentsOf: file)
        }
        if data == nil, !choice.local, choice.bundled == nil, let url = choice.url, let (d, r) = try? await DataFetcher.session.data(from: url),
           (r as? HTTPURLResponse)?.statusCode == 200, d.count <= maxBytes {
            data = d
            try? d.write(to: file, options: .atomic)
        }
        guard let data else { return nil }
        let box = UncheckedBox(data)
        let parsed = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<SCNNode>? in
            (try? GLBLoader.load(box.value)).map { UncheckedBox($0) }
        }.value
        guard let node = parsed?.value else {
            // A bad download shouldn't stick around and fail forever.
            if !choice.local, choice.bundled == nil { try? FileManager.default.removeItem(at: file) }
            return nil
        }
        var stray: [SCNNode] = []
        node.enumerateHierarchy { n, _ in
            if let name = n.name, choice.hidden.contains(where: { name.hasPrefix($0) }) { stray.append(n) }
        }
        stray.forEach { $0.removeFromParentNode() }
        memory[choice.path] = node
        order.append(choice.path)
        if order.count > 6 { memory[order.removeFirst()] = nil }
        return node.clone()
    }
}
