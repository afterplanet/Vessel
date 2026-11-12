import CoreLocation
import Foundation

/// Where this Mac is, asked for only when the crosshair is clicked and kept only as the chosen location.
struct FoundLocation: Equatable {
    enum Method: Equatable { case wifi, internetAddress }
    let latitude: Double
    let longitude: Double
    let method: Method
    /// Metres, where the method can say.
    var accuracy: Double?
    /// What the lookup itself says the place is called. Wi-Fi gives only coordinates.
    var name: String?
    var iso: String?
}

/// What macOS works out from nearby Wi-Fi networks, as a Mac has no GPS. It asks permission the first time.
@MainActor
final class WifiLocator: NSObject, CLLocationManagerDelegate {
    enum Outcome: Equatable {
        case found(latitude: Double, longitude: Double, accuracy: Double)
        case notAllowed
        case failed
    }

    /// Long enough for someone to answer the permission question.
    private static let answerTime: Duration = .seconds(60)
    private static let lookupTime: Duration = .seconds(12)

    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeout: Task<Void, Never>?
    private var asked = false

    func locate() async -> Outcome {
        await withCheckedContinuation { c in
            continuation = c
            let m = CLLocationManager()
            m.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager = m
            m.delegate = self
            proceed(m)
        }
    }

    private func proceed(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined:
            startTimeout(Self.answerTime)
            m.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.notAllowed)
        default:
            guard !asked else { return }
            asked = true
            startTimeout(Self.lookupTime)
            m.requestLocation()
        }
    }

    private func startTimeout(_ time: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: time)
            if !Task.isCancelled { self?.finish(.failed) }
        }
    }

    private func finish(_ outcome: Outcome) {
        timeout?.cancel()
        timeout = nil
        guard let c = continuation else { return }
        continuation = nil
        manager?.delegate = nil
        manager = nil
        c.resume(returning: outcome)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        MainActor.assumeIsolated { if continuation != nil { proceed(m) } }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        let found = Outcome.found(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, accuracy: l.horizontalAccuracy)
        MainActor.assumeIsolated { finish(found) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated { finish(denied ? .notAllowed : .failed) }
    }
}

/// Roughly where the internet connection comes out, from services that look up its address.
enum IPLocation {
    static let services = ["https://ipwho.is/", "https://ipapi.co/json/"]

    static func parse(_ data: Data) -> FoundLocation? {
        struct Reply: Decodable {
            let success: Bool?
            let error: Bool?
            let latitude: Double?
            let longitude: Double?
            let city: String?
            let region: String?
            let country: String?
            let country_name: String?
            let country_code: String?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), r.success != false, r.error != true,
              let lat = r.latitude, let lon = r.longitude,
              abs(lat) <= 90, abs(lon) <= 180,
              // Services answer 0, 0 when they don't know.
              lat != 0 || lon != 0 else { return nil }
        var seen = Set<String>()
        let parts = [r.city, r.region, r.country_name ?? r.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return FoundLocation(latitude: lat, longitude: lon, method: .internetAddress,
                             name: parts.isEmpty ? nil : parts.joined(separator: ", "),
                             iso: r.country_code?.lowercased())
    }

    /// Uses no cache: this is someone's location, and it should neither be stale nor left on disk.
    static func look() async -> FoundLocation? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        for service in services {
            guard let url = URL(string: service) else { continue }
            var request = URLRequest(url: url)
            request.setValue(AMSATAPI.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let found = parse(data) else { continue }
            return found
        }
        return nil
    }
}

/// Why the GPS popup is showing, and whether there's another way.
struct GPSOffer: Identifiable, Equatable {
    let id = UUID()
    let reason: String
    let canUseInternet: Bool
}

/// A line under the address bar saying how the location was found.
struct LocationNote: Equatable {
    let text: String
    let symbol: String
    let isWarning: Bool
    /// Approximate, so there's a better answer to be had from the satellites.
    var offersGPSScan = false

    static func wifi(accuracy: Double?) -> LocationNote {
        var text = "Found using nearby Wi-Fi"
        if let accuracy, accuracy > 0 { text += ", " + within(accuracy) }
        return LocationNote(text: text, symbol: "wifi", isWarning: false)
    }

    static func internetAddress(wifi: WifiLocator.Outcome) -> LocationNote {
        let reason = wifi == .notAllowed
            ? "To use Wi-Fi instead, allow Vessel in System Settings, Privacy & Security, Location Services."
            : "Wi-Fi positioning didn't answer."
        return LocationNote(text: "Approximate, from your internet address, and a VPN would move it. \(reason)", symbol: "network", isWarning: true, offersGPSScan: true)
    }

    static func gps(spread: Double) -> LocationNote {
        LocationNote(text: "Pinned from GPS, \(within(max(spread, 5))). It stays in the address search until you delete it.", symbol: "location.fill", isWarning: false)
    }

    static let notFound = LocationNote(text: "Couldn't find your location. Check your connection, or type an address.", symbol: "exclamationmark.triangle.fill", isWarning: true)

    static func within(_ metres: Double) -> String {
        if metres < 1000 { return "within about \(Int((metres / 10).rounded() * 10)) m" }
        return "within about \(Int((metres / 1000).rounded())) km"
    }
}
