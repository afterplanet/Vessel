import SwiftUI
import simd

/// A satellite signal that should be somewhere in the spectrum being shown right now.
struct SpectrumMark: Identifiable, Equatable {
    let id: String
    let norad: Int
    let name: String
    /// Where it's expected on the dial, after Doppler.
    let hz: Double
    let nominalHz: Double
    /// Width of a transponder's passband, or 0 for a single frequency.
    let widthHz: Double
    let mode: String
    let elevation: Double
}

/// Works out which satellites above the horizon transmit inside the visible span, and where
/// Doppler puts each one. Names on the spectrum come from here.
@MainActor
final class WaterfallLabels: ObservableObject {
    @Published private(set) var labels: [SpectrumMark] = []
    @Published private(set) var hint = ""

    private weak var store: SatelliteStore?
    private weak var app: AppState?
    private var timer: Timer?
    private var copies: [Int: Satellite] = [:]

    func attach(store: SatelliteStore, app: AppState) {
        self.store = store
        self.app = app
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Where a row of names can go without overlapping: each takes the first row with room.
    nonisolated static func rows(centres: [CGFloat], widths: [CGFloat], maxRows: Int) -> [Int?] {
        var ends = [CGFloat](repeating: -.infinity, count: maxRows)
        var out = [Int?](repeating: nil, count: centres.count)
        for i in centres.indices.sorted(by: { centres[$0] < centres[$1] }) {
            let start = centres[i] - widths[i] / 2
            if let row = ends.indices.first(where: { ends[$0] + 4 <= start }) {
                ends[row] = start + widths[i]
                out[i] = row
            }
        }
        return out
    }

    /// Pure part, for tests: which transmitters fall in the span once Doppler has moved them.
    nonisolated static func visible(transmitters: [Transmitter], rangeRate: Double, centre: Double, span: Double) -> [(tx: Transmitter, hz: Double)] {
        transmitters.compactMap { t in
            guard t.active, t.downlinkHz > 0 else { return nil }
            let mid = (t.downlinkHz + max(t.downlinkHighHz ?? t.downlinkHz, t.downlinkHz)) / 2
            let hz = Doppler.downlink(mid, rangeRate: rangeRate)
            return abs(hz - centre) <= span / 2 ? (t, hz) : nil
        }
    }

    func refresh(now: Date = Date()) {
        guard let app, let store else { return }
        let feed = app.runner.spectrum
        guard app.showSpectrum, let centre = feed.frequencyHz, feed.sampleRate > 0 else {
            if !labels.isEmpty { labels = [] }
            return
        }
        guard let st = app.station else {
            labels = []
            hint = "Set a location to name the signals"
            return
        }
        hint = ""
        let span = feed.sampleRate
        let ground = GroundPoint(lat: st.lat, lon: st.lon)
        let jd = Astro.julianDate(now), jd2 = jd + 1.0 / 86400
        var out: [SpectrumMark] = []
        // Doppler never moves a signal by more than about 25 parts per million.
        let reach = span / 2 + centre * 3e-5
        for sat in store.satellites where sat.transmitters.contains(where: { $0.active && abs($0.downlinkHz - centre) <= reach + (($0.downlinkHighHz ?? $0.downlinkHz) - $0.downlinkHz) }) {
            if copies[sat.norad] == nil { copies[sat.norad] = sat.clone() }
            guard let c = copies[sat.norad], let r1 = c.position(jd: jd), let r2 = c.position(jd: jd2) else { continue }
            let p1 = Astro.ecef(r1, gmst: Astro.gmst(jd)), p2 = Astro.ecef(r2, gmst: Astro.gmst(jd2))
            let el = ground.elevation(of: p1)
            guard el > 0 else { continue }
            let rate = simd_length(p2 - ground.position) - simd_length(p1 - ground.position)
            for (i, hit) in Self.visible(transmitters: sat.transmitters, rangeRate: rate, centre: centre, span: span).enumerated() {
                let t = hit.tx
                // A correction saved for this signal moves its name too.
                let shift = app.savedOffset(norad: sat.norad, hz: t.downlinkHz)
                out.append(SpectrumMark(id: "\(sat.norad)-\(i)-\(Int(t.downlinkHz))", norad: sat.norad, name: sat.name, hz: hit.hz + shift,
                                       nominalHz: t.downlinkHz, widthHz: max(0, (t.downlinkHighHz ?? t.downlinkHz) - t.downlinkHz),
                                       mode: t.mode, elevation: el))
            }
        }
        // Several transmitters of one satellite on the same frequency need only one name.
        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.norad)-\(Int($0.hz / 2000))").inserted }
        if out != labels { labels = out }
        if copies.count > 600 { copies = [:] }
    }
}

/// Names and tick marks over the spectrum plot. Click a name to lock that satellite and tune to it.
struct SpectrumLabelLayer: View {
    @ObservedObject var source: WaterfallLabels
    let centre: Double
    let span: Double
    let lockedID: Int?
    let onPick: (SpectrumMark) -> Void

    private static func width(_ l: SpectrumMark) -> CGFloat { CGFloat(min(l.name.count, 18)) * 5.6 + 8 }

    private func x(_ hz: Double, _ w: CGFloat) -> CGFloat { w * CGFloat((hz - centre) / span + 0.5) }

    var body: some View {
        GeometryReader { g in
            // Highest satellites get first pick of the rows, as they're the strongest.
            let sorted = source.labels.sorted { $0.elevation > $1.elevation }
            let rows = WaterfallLabels.rows(centres: sorted.map { x($0.hz, g.size.width) }, widths: sorted.map(Self.width), maxRows: max(1, Int((g.size.height - 14) / 13)))
            ZStack(alignment: .topLeading) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, l in
                    let px = x(l.hz, g.size.width)
                    let colour: Color = l.norad == lockedID ? .orange : .yellow
                    if l.widthHz > 0 {
                        Rectangle().fill(colour.opacity(0.18))
                            .frame(width: max(2, g.size.width * CGFloat(l.widthHz / span)), height: g.size.height)
                            .position(x: px, y: g.size.height / 2)
                            .allowsHitTesting(false)
                    }
                    Rectangle().fill(colour.opacity(0.7)).frame(width: 1, height: g.size.height)
                        .position(x: px, y: g.size.height / 2)
                        .allowsHitTesting(false)
                    if let row = rows[i] {
                        Button { onPick(l) } label: {
                            Text(l.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 3).padding(.vertical, 0.5)
                                .frame(maxWidth: Self.width(l))
                                .background(colour.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .position(x: min(max(px, Self.width(l) / 2), g.size.width - Self.width(l) / 2), y: 14 + CGFloat(row) * 13 + 6)
                        .help("\(l.name), \(spectrumLabel(l.hz)) \(l.mode), \(Int(l.elevation))° up. Click to tune.")
                    }
                }
                if !source.hint.isEmpty {
                    Text(source.hint).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                        .position(x: g.size.width / 2, y: g.size.height - 8)
                }
            }
        }
    }
}
