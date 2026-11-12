import SwiftUI

/// What the SatNOGS network of ground stations says about a satellite: whether anyone has
/// really heard it lately, and the waterfall to prove it.
@MainActor
final class SatNOGSReport: ObservableObject {
    struct Observation: Decodable, Equatable {
        let id: Int
        let start: String
        let station_name: String?
        let transmitter_downlink_low: Double?
        let transmitter_mode: String?
        let waterfall: String?

        var date: Date? { ISO8601DateFormatter().date(from: start) }
        var page: URL? { URL(string: "https://network.satnogs.org/observations/\(id)/") }
    }

    private struct DBSatellite: Decodable {
        let image: String?
        let status: String?
    }

    struct Info: Equatable {
        var latest: Observation?
        var photo: URL?
        var status: String?
    }

    @Published private(set) var info: Info?
    @Published private(set) var isLoading = false

    private static var cache: [Int: (info: Info, at: Date)] = [:]
    private static let keep: TimeInterval = 600

    private static func decode<T: Decodable>(_ type: T.Type, from url: String) async -> T? {
        guard let u = URL(string: url), let (d, r) = try? await DataFetcher.session.data(from: u),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func load(norad: Int) async {
        if let c = Self.cache[norad], Date().timeIntervalSince(c.at) < Self.keep {
            info = c.info
            return
        }
        info = nil
        isLoading = true
        defer { isLoading = false }
        async let observations = Self.decode([Observation].self, from: "https://network.satnogs.org/api/observations/?norad_cat_id=\(norad)&status=good&format=json")
        async let satellites = Self.decode([DBSatellite].self, from: "https://db.satnogs.org/api/satellites/?norad_cat_id=\(norad)&format=json")
        let (o, s) = await (observations, satellites)
        if Task.isCancelled { return }
        let image = s?.first?.image.flatMap { $0.isEmpty ? nil : $0 }
        let fresh = Info(latest: o?.first, photo: image.flatMap { URL(string: "https://db-satnogs.freetls.fastly.net/media/\($0)") }, status: s?.first?.status)
        // A failed request isn't remembered, so it gets another try on the next lock.
        if o != nil || s != nil { Self.cache[norad] = (fresh, Date()) }
        info = fresh
    }
}

/// Part of the Satellite panel.
struct SatNOGSSection: View {
    @StateObject private var report = SatNOGSReport()
    let satellite: Satellite

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SatNOGS").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) { summary }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11))
            if let info = report.info, info.latest?.waterfall != nil || info.photo != nil { images(info) }
        }
        .task(id: satellite.norad) { await report.load(norad: satellite.satnogsNorad) }
    }

    @ViewBuilder private var summary: some View {
        if report.isLoading {
            Text("Checking…").foregroundStyle(.secondary)
        } else if let o = report.info?.latest {
            if let d = o.date { Text("Heard ") + Text(d, style: .relative) + Text(" ago") } else { Text("Heard recently") }
            Text([o.station_name, o.transmitter_downlink_low.map(formatHz), o.transmitter_mode].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary).font(.system(size: 10)).lineLimit(2)
        } else {
            Text("No recent reports").foregroundStyle(.secondary)
        }
    }

    private func images(_ info: SatNOGSReport.Info) -> some View {
        HStack(spacing: 6) {
            if let s = info.latest?.waterfall, let u = URL(string: s) {
                thumb(u, label: "Waterfall", open: info.latest?.page ?? u)
            }
            if let p = info.photo { thumb(p, label: "Photo", open: p) }
        }
    }

    private func thumb(_ url: URL, label: String, open: URL) -> some View {
        Button { NSWorkspace.shared.open(open) } label: {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.black.opacity(0.3))
                }
            }
            .frame(height: 56).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomLeading) {
                Text(label).font(.system(size: 9)).foregroundStyle(.white).shadow(radius: 2).padding(3)
            }
        }
        .buttonStyle(.plain)
        .help("From SatNOGS. Click to open.")
    }
}
