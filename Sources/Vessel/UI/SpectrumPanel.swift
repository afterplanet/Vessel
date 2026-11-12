import SwiftUI
import CoreGraphics

/// The live spectrum from the receiver, kept apart from the runner so that its several updates a
/// second redraw only this window and not the whole sidebar.
@MainActor
final class SpectrumFeed: ObservableObject {
    @Published private(set) var values: [Float] = []
    @Published private(set) var waterfall: CGImage?
    @Published private(set) var floorDB: Float = -80
    @Published private(set) var topDB: Float = -40
    @Published private(set) var frequencyHz: Double?
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var mode: CaptureMode?

    static let rows = 140
    private var pixels: [UInt8] = []
    private var width = 0

    func begin(frequency: Double, sampleRate: Double, mode: CaptureMode) {
        frequencyHz = frequency
        self.sampleRate = sampleRate
        self.mode = mode
        values = []
        waterfall = nil
        pixels = []
        width = 0
    }

    /// The last spectrum stays on screen so it can still be read after stopping.
    func end() { mode = nil }

    func update(_ fresh: [Float]) {
        guard !fresh.isEmpty else { return }
        let sorted = fresh.sorted()
        // The noise floor sits a little above the bottom of the scale, so it reads as a band.
        let floorNow = sorted[sorted.count / 2] - 8
        let topNow = max(floorNow + 28, sorted[sorted.count * 995 / 1000] + 5)
        // Eased, so the scale doesn't jump about with every update.
        floorDB = values.isEmpty ? floorNow : floorDB * 0.85 + floorNow * 0.15
        topDB = values.isEmpty ? topNow : topDB * 0.85 + topNow * 0.15
        // The very first frame has no settled scale yet, and would leave a stray line in the history.
        if !values.isEmpty { addRow(fresh) }
        values = fresh
    }

    private func addRow(_ v: [Float]) {
        if width != v.count {
            width = v.count
            pixels = [UInt8](repeating: 0, count: width * Self.rows * 4)
        }
        let rowBytes = width * 4
        // Newest at the top: everything else moves down a row.
        pixels.withUnsafeMutableBytes { p in
            guard let base = p.baseAddress else { return }
            memmove(base + rowBytes, base, rowBytes * (Self.rows - 1))
        }
        let span = max(topDB - floorDB, 1)
        for x in 0..<width {
            let c = Self.color((v[x] - floorDB) / span)
            pixels[x * 4] = c.0; pixels[x * 4 + 1] = c.1; pixels[x * 4 + 2] = c.2; pixels[x * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return }
        waterfall = CGImage(width: width, height: Self.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Dark blue through cyan and yellow to white as strength rises.
    nonisolated static func color(_ level: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0.02, 0.02, 0.1), (0.05, 0.2, 0.6), (0.05, 0.75, 0.8), (0.95, 0.85, 0.2), (1, 1, 1)]
        let t = min(0.999, max(0, level)) * Float(stops.count - 1)
        let i = Int(t), f = t - Float(i)
        let a = stops[i], b = stops[i + 1]
        return (UInt8((a.0 + (b.0 - a.0) * f) * 255), UInt8((a.1 + (b.1 - a.1) * f) * 255), UInt8((a.2 + (b.2 - a.2) * f) * 255))
    }

    /// Peaks standing well above the noise, strongest first, for checks.
    func strongestPeaksHz(_ count: Int) -> [Double] {
        Self.peaks(values, frequency: frequencyHz ?? 0, sampleRate: sampleRate, count: count)
    }

    nonisolated static func peaks(_ v: [Float], frequency f: Double, sampleRate: Double, count: Int) -> [Double] {
        guard v.count > 40 else { return [] }
        let floorDB = v.sorted()[v.count / 2]
        var found: [(Int, Float)] = []
        for i in 20..<(v.count - 20) where v[i] > floorDB + 6 && v[i] == v[(i - 20)...(i + 20)].max() {
            found.append((i, v[i]))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(count).map { f + (Double($0.0) / Double(v.count) - 0.5) * sampleRate }
    }

    /// The strongest bin's frequency, for checks.
    var peakHz: Double? {
        guard let f = frequencyHz, let i = values.indices.max(by: { values[$0] < values[$1] }), !values.isEmpty else { return nil }
        return f + (Double(i) / Double(values.count) - 0.5) * sampleRate
    }
}

func spectrumLabel(_ hz: Double) -> String {
    hz >= 1e9 ? String(format: "%.4f GHz", hz / 1e9) : String(format: "%.3f MHz", hz / 1e6)
}

/// Floating window at the top right of the globe. The arrows button makes it larger.
struct SpectrumPanel: View {
    @ObservedObject var feed: SpectrumFeed
    let available: CGSize
    let onClose: () -> Void
    /// Names of the satellites in view of the span. Left out in previews and tests.
    var labels: WaterfallLabels? = nil
    var lockedID: Int? = nil
    var onPick: (SpectrumMark) -> Void = { _ in }
    @State private var expanded: Bool
    @State private var hoverX: CGFloat?

    init(feed: SpectrumFeed, available: CGSize, startExpanded: Bool = false, onClose: @escaping () -> Void,
         labels: WaterfallLabels? = nil, lockedID: Int? = nil, onPick: @escaping (SpectrumMark) -> Void = { _ in }) {
        self.labels = labels
        self.lockedID = lockedID
        self.onPick = onPick
        self.feed = feed
        self.available = available
        self.onClose = onClose
        _expanded = State(initialValue: startExpanded)
    }

    private var width: CGFloat { expanded ? min(620, max(320, available.width - 24)) : 320 }
    private var plotHeight: CGFloat { expanded ? min(190, max(80, available.height * 0.24)) : 84 }
    private var waterfallHeight: CGFloat { expanded ? min(190, max(60, available.height * 0.24)) : 62 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            plot.frame(height: plotHeight)
                .overlay {
                    if let labels, let f = feed.frequencyHz, feed.sampleRate > 0 {
                        SpectrumLabelLayer(source: labels, centre: f, span: feed.sampleRate, lockedID: lockedID, onPick: onPick)
                    }
                }
            waterfall.frame(height: waterfallHeight)
            axis
        }
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(modeWord).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(feed.frequencyHz.map(spectrumLabel) ?? "No frequency")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            Spacer()
            statusBadge
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Make smaller" : "Make larger")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close spectrum")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var modeWord: String {
        switch feed.mode {
        case .record: "Recording on"
        case .listen: "Listening on"
        case nil: "Last tuned to"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch feed.mode {
        case .record:
            badge("REC", color: .red, pulsing: true)
        case .listen:
            badge("LIVE", color: .green, pulsing: false)
        case nil:
            badge("STOPPED", color: .secondary, pulsing: false)
        }
    }

    private func badge(_ text: String, color: Color, pulsing: Bool) -> some View {
        HStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: 0.25, paused: !pulsing)) { c in
                let on = !pulsing || Int(c.date.timeIntervalSinceReferenceDate * 1.6) % 2 == 0
                Circle().fill(color).frame(width: 7, height: 7).opacity(on ? 1 : 0.3)
            }
            .frame(width: 7, height: 7)
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
        }
    }

    private var plot: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.75)))
            let line = Color.white.opacity(0.1)
            for i in 1..<4 {
                let y = size.height * CGFloat(i) / 4
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(line), lineWidth: 0.5)
            }
            let v = feed.values
            let range = max(feed.topDB - feed.floorDB, 1)
            let bottomDB = feed.floorDB
            let span = range
            if v.count > 1 {
                var trace = Path()
                for (i, value) in v.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(v.count - 1)
                    let level = CGFloat(min(1, max(0, (value - bottomDB) / span)))
                    let pt = CGPoint(x: x, y: size.height * (1 - level))
                    if i == 0 { trace.move(to: pt) } else { trace.addLine(to: pt) }
                }
                var fill = trace
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(.cyan.opacity(0.16)))
                ctx.stroke(trace, with: .color(.cyan), lineWidth: 1)
            }
            // The tuned frequency is always the centre of the span.
            var centre = Path(); centre.move(to: CGPoint(x: size.width / 2, y: 0)); centre.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            ctx.stroke(centre, with: .color(feed.mode == .record ? .red : .orange), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text(String(format: "%.0f dB", feed.topDB)).font(.system(size: 8)).foregroundStyle(.white.opacity(0.55)), at: CGPoint(x: 4, y: 3), anchor: .topLeading)
            ctx.draw(Text(String(format: "%.0f dB", bottomDB)).font(.system(size: 8)).foregroundStyle(.white.opacity(0.55)), at: CGPoint(x: 4, y: size.height - 3), anchor: .bottomLeading)
            if v.isEmpty {
                ctx.draw(Text("Waiting for the receiver…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            if let x = hoverX, let f = feed.frequencyHz, feed.sampleRate > 0 {
                var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(cursor, with: .color(.white.opacity(0.6)), lineWidth: 0.75)
                let hz = f + (Double(x / size.width) - 0.5) * feed.sampleRate
                let leftSide = x < size.width - 90
                ctx.draw(Text(spectrumLabel(hz)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white),
                         at: CGPoint(x: x + (leftSide ? 5 : -5), y: 4), anchor: leftSide ? .topLeading : .topTrailing)
            }
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
        }
    }

    private var waterfall: some View {
        ZStack {
            Color.black
            if let img = feed.waterfall {
                Image(decorative: img, scale: 1).resizable().interpolation(.none)
            }
        }
    }

    private var axis: some View {
        HStack {
            Text(edge(-0.5))
            Spacer()
            Text(feed.frequencyHz.map(spectrumLabel) ?? "").fontWeight(.medium)
            Spacer()
            Text(edge(0.5))
        }
        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func edge(_ side: Double) -> String {
        guard let f = feed.frequencyHz, feed.sampleRate > 0 else { return "" }
        return spectrumLabel(f + side * feed.sampleRate)
    }
}
