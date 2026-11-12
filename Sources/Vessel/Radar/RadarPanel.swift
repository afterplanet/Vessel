import SwiftUI

extension OrbitClass {
    var color: Color {
        let c = Palette.color(self)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

/// Bottom-right panel: a sky plot for the selected address, what's overhead, and what rises next.
struct RadarPanel: View {
    @EnvironmentObject var radar: RadarTracker
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore
    @EnvironmentObject var planner: PassPlanner
    @State private var expanded: Bool
    @State private var overheadExpanded: Bool

    init(startExpanded: Bool = false, overheadOpen: Bool = false) {
        _expanded = State(initialValue: startExpanded)
        _overheadExpanded = State(initialValue: overheadOpen)
    }

    private func allowed(_ id: Int) -> Bool { store.satellite(norad: id)?.filteredOut != true }

    /// What's in view, highest first: the highest few, plus anything from the approaching list
    /// that has risen since, so an arrival always shows however low it is.
    private var passing: [RadarBlip] {
        RadarTracker.inView(radar.blips, filter: app.orbitFilter, arrived: radar.arrived, keep: allowed)
    }

    /// A locked satellite stays on the plot wherever it is in the sky.
    private var shown: [RadarBlip] {
        var list = passing
        if let id = app.locked?.norad, !list.contains(where: { $0.id == id }), let b = radar.blips.first(where: { $0.id == id }) {
            list.append(b)
        }
        return list
    }

    private var upcoming: [Approach] {
        let now = Date()
        return radar.approaches.lazy
            .filter { $0.aos > now && (app.orbitFilter == nil || $0.orbit == app.orbitFilter) && store.satellite(norad: $0.id)?.filteredOut != true }
            .prefix(10).map { $0 }
    }

    private var overhead: RadarBlip? { passing.first }

    /// The locked satellite's pass in view now, or its next one, for drawing its path.
    private var lockedPass: SatPass? {
        guard let id = app.locked?.norad, planner.satelliteID == id else { return nil }
        let now = Date()
        return planner.passes.first { $0.los > now }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Radar").font(.system(size: 12, weight: .semibold))
                Spacer()
                if radar.hasStation {
                    Text("\(passing.count) passing")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .help("The highest \(RadarTracker.maxShown) above the horizon that your filters allow, of \(radar.blips.count.formatted()) above the horizon")
                }
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 5)

            if radar.hasStation {
                RadarScope(blips: shown, lockedID: app.locked?.norad, track: planner.selected?.track ?? [],
                           arrived: radar.arrived,
                           lockedPass: lockedPass, lockedColor: app.locked?.orbit.color ?? .white, label: { store.satellite(norad: $0) }) { lock(norad: $0) }
                    .frame(width: 186, height: 186)
                    .padding(.bottom, 8)
                if app.locked != nil {
                    Divider()
                    pinnedRow
                }
                Divider()
                overheadRow
                if overheadExpanded {
                    Divider()
                    overheadList
                }
                Divider()
                nextRow
                if expanded {
                    Divider()
                    list
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 20, weight: .light))
                    Text("Set an address to see the sky above it")
                        .font(.system(size: 11)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26).padding(.horizontal, 12)
            }
        }
        .frame(width: 252)
        .onChange(of: upcoming, initial: true) { _, list in radar.watch(list) }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }

    private func lock(norad: Int) {
        if let s = store.satellite(norad: norad) { app.lock(s) }
    }

    /// The satellite picked here stays pinned, with when it arrives and when it leaves.
    @ViewBuilder private var pinnedRow: some View {
        if let sat = app.locked {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                    FlagView(iso: sat.countryISO, height: 12)
                    Text(sat.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button { app.unlock() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Unpin")
                }
                pinnedTimes
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.14))
        }
    }

    @ViewBuilder private var pinnedTimes: some View {
        switch app.pass {
        case .pass(let p):
            // Checked every second, so the words change the moment it rises or sets.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let inView = p.inProgress || now >= p.aos
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        timeColumn("AOS", inView ? "In view" : Self.clock(p.aos))
                        timeColumn("Leaves", Self.clock(p.los))
                        timeColumn("Max", "\(Int(p.maxElevation))°")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        if let sat = app.locked { lockColumn(sat) }
                        Text(Self.pinnedCountdown(p, now: now))
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .computing, .unknown:
            Text("Working out its next pass…").font(.system(size: 10)).foregroundStyle(.secondary)
        case .alwaysVisible:
            Text("Always above the horizon here").font(.system(size: 10)).foregroundStyle(.secondary)
        case .none:
            Text("No pass here in the next 3 days").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// The time, with the day when it isn't today.
    static func clock(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Arrives in 3h 12m" before it rises, "Leaves in 4m 10s" while it's up, and a holding line
    /// in the moment between it setting and its next pass being worked out.
    nonisolated static func pinnedCountdown(_ p: PassInfo, now: Date) -> String {
        if now >= p.los { return "Left. Working out its next pass…" }
        if p.inProgress || now >= p.aos { return "Leaves in " + span(p.los.timeIntervalSince(now)) }
        return "Arrives in " + span(p.aos.timeIntervalSince(now))
    }

    nonisolated static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    private func timeColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
        }
    }

    @ViewBuilder private var overheadRow: some View {
        if let b = overhead, let sat = store.satellite(norad: b.id) {
            Button {
                if passing.count > 1 {
                    withAnimation(.snappy(duration: 0.2)) { overheadExpanded.toggle() }
                } else {
                    app.lock(sat)
                }
            } label: {
                row(caption: passing.count > 1 ? "Now overhead · \(passing.count)" : "Now overhead", sat: sat) {
                    endColumns(sat, chevron: passing.count > 1, open: overheadExpanded) { Text("\(Int(b.elevation))°") }
                }
            }
            .buttonStyle(.plain)
            .help(passing.count > 1 ? (overheadExpanded ? "Hide the list" : "Show all \(passing.count) in view") : "Lock \(sat.name)")
            .contextMenu { Button("Lock \(sat.name)") { app.lock(sat) } }
        } else {
            placeholderRow(caption: "Now overhead", text: "Nothing passing right now")
        }
    }

    @ViewBuilder private var nextRow: some View {
        if let next = upcoming.first, let sat = store.satellite(norad: next.id) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                row(caption: "Next approaching", sat: sat) {
                    endColumns(sat, chevron: true, open: expanded) {
                        Text(timerInterval: Date()...max(next.aos, Date()), countsDown: true)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the list" : "Show the next 10")
        } else {
            placeholderRow(caption: "Next approaching", text: radar.approaches.isEmpty ? "Working it out…" : "None coming soon")
        }
    }

    /// Everything in view, highest first, with how high each is.
    private var overheadList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(passing) { b in
                    if let sat = store.satellite(norad: b.id) {
                        Button { app.lock(sat) } label: {
                            HStack(spacing: 7) {
                                // Ringed, as on the plot, when it's one that was approaching.
                                Circle().fill(b.orbit.color).frame(width: 6, height: 6)
                                    .overlay {
                                        if radar.arrived.contains(b.id) {
                                            Circle().strokeBorder(b.orbit.color, lineWidth: 1).frame(width: 10, height: 10)
                                        }
                                    }
                                FlagView(iso: sat.countryISO, height: 11)
                                Text(sat.name).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 4)
                                endColumns(sat) { Text("\(Int(b.elevation))°") }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(app.locked?.norad == sat.norad ? Color.accentColor.opacity(0.3) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(radar.arrived.contains(b.id) ? "Just arrived. Lock \(sat.name), \(sat.countryName)" : "Lock \(sat.name), \(sat.countryName)")
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .frame(maxHeight: 190)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(upcoming) { a in
                if let sat = store.satellite(norad: a.id) {
                    Button { app.lock(sat) } label: {
                        HStack(spacing: 7) {
                            Circle().fill(a.orbit.color).frame(width: 6, height: 6)
                            FlagView(iso: sat.countryISO, height: 11)
                            Text(sat.name).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 4)
                            endColumns(sat) { Text(timerInterval: Date()...max(a.aos, Date()), countsDown: true) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(app.locked?.norad == sat.norad ? Color.accentColor.opacity(0.3) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Lock \(sat.name), \(sat.countryName)")
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// A fixed column, whether there's a lock or not, so the times line up down the list.
    private func lockColumn(_ sat: Satellite) -> some View {
        let state = sat.encryption.state
        return Group {
            if let symbol = state.symbol { Image(systemName: symbol) } else { Color.clear }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .frame(width: 11, height: 11)
        .help(state == .yes ? "Encrypted" : state == .partly ? "Partly encrypted" : state == .no ? "Not encrypted" : "")
    }

    /// The columns at the end of every row: lock, time or height, and the list's chevron.
    private func endColumns<V: View>(_ sat: Satellite, chevron: Bool = false, open: Bool = false, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 5) {
            lockColumn(sat)
            value().font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 44, alignment: .trailing)
            Group {
                if chevron {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)
        }
    }

    private func row<T: View>(caption: String, sat: Satellite, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 8) {
            FlagView(iso: sat.countryISO, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Text(sat.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func placeholderRow(caption: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

/// The sky seen from the address: straight up is the centre, the horizon is the rim, north is up.
struct RadarScope: View {
    let blips: [RadarBlip]
    let lockedID: Int?
    /// A chosen pass, drawn as its path across the sky.
    var track: [SatPass.Point] = []
    /// Risen from the approaching list, drawn with a ring so the arrival stands out.
    var arrived: Set<Int> = []
    /// The locked satellite's current or next pass, drawn as a thin line in its type's colour.
    var lockedPass: SatPass? = nil
    var lockedColor: Color = .white
    /// The satellite behind a blip, for the hover label.
    var label: (Int) -> Satellite? = { _ in nil }
    let onSelect: (Int) -> Void

    @State private var hovered: (id: Int, at: CGPoint)?

    private static let size: CGFloat = 186

    /// How far through the pass it is, from 0 before it rises to 1 once it has set.
    nonisolated static func travelled(_ pass: SatPass, at now: Date) -> Double {
        let d = pass.los.timeIntervalSince(pass.aos)
        guard d > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(pass.aos) / d))
    }

    private func nearest(_ loc: CGPoint) -> (id: Int, at: CGPoint)? {
        let c = CGPoint(x: Self.size / 2, y: Self.size / 2), R = Self.size / 2 - 11
        var best: (id: Int, at: CGPoint, d: CGFloat)?
        for b in blips {
            let p = point(b, center: c, radius: R)
            let d = hypot(p.x - loc.x, p.y - loc.y)
            if d < 10, d < (best?.d ?? .infinity) { best = (b.id, p, d) }
        }
        return best.map { ($0.id, $0.at) }
    }

    private func point(_ b: RadarBlip, center: CGPoint, radius: CGFloat) -> CGPoint {
        let r = CGFloat((90 - b.elevation) / 90) * radius
        let a = b.azimuth * .pi / 180
        return CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 11
                let line = Color.green.opacity(0.28)

                ctx.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)), with: .color(.black.opacity(0.55)))
                for f in [1.0 / 3, 2.0 / 3, 1.0] {
                    let r = R * CGFloat(f)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(line), lineWidth: 0.75)
                }
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - R, y: c.y)); cross.addLine(to: CGPoint(x: c.x + R, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - R)); cross.addLine(to: CGPoint(x: c.x, y: c.y + R))
                ctx.stroke(cross, with: .color(line), lineWidth: 0.75)

                // The sweep, as a fading wedge behind a bright leading edge.
                let t = context.date.timeIntervalSinceReferenceDate
                let sweep = t.truncatingRemainder(dividingBy: 6) / 6 * 360 - 90
                for i in 0..<14 {
                    var wedge = Path()
                    wedge.move(to: c)
                    wedge.addArc(center: c, radius: R, startAngle: .degrees(sweep - Double(i + 1) * 4), endAngle: .degrees(sweep - Double(i) * 4), clockwise: false)
                    wedge.closeSubpath()
                    ctx.fill(wedge, with: .color(.green.opacity(0.2 * (1 - Double(i) / 14))))
                }

                func spot(_ p: SatPass.Point) -> CGPoint {
                    let r = CGFloat((90 - p.el) / 90) * R, a = p.az * .pi / 180
                    return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
                }
                // The locked satellite's path across the sky: faint where it has been, solid
                // where it's still to go, with a small dot where it rises and a ring where it sets.
                if let pass = lockedPass, pass.track.count > 1, pass.track != track {
                    let pts = pass.track.map(spot)
                    let done = RadarScope.travelled(pass, at: context.date)
                    let split = done * Double(pts.count - 1)
                    let i = min(pts.count - 2, Int(split)), f = CGFloat(split - Double(i))
                    let here = CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * f, y: pts[i].y + (pts[i + 1].y - pts[i].y) * f)
                    let style = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                    if done > 0 {
                        var behind = Path(); behind.move(to: pts[0])
                        for p in pts[1...i] { behind.addLine(to: p) }
                        behind.addLine(to: here)
                        ctx.stroke(behind, with: .color(lockedColor.opacity(0.35)), style: style)
                    }
                    var ahead = Path(); ahead.move(to: done > 0 ? here : pts[0])
                    for p in pts[(done > 0 ? i + 1 : 1)...] { ahead.addLine(to: p) }
                    ctx.stroke(ahead, with: .color(lockedColor.opacity(0.95)), style: style)
                    let a = pts[0], b = pts[pts.count - 1]
                    ctx.fill(Path(ellipseIn: CGRect(x: a.x - 2, y: a.y - 2, width: 4, height: 4)), with: .color(lockedColor))
                    ctx.stroke(Path(ellipseIn: CGRect(x: b.x - 2.5, y: b.y - 2.5, width: 5, height: 5)), with: .color(lockedColor), lineWidth: 1)
                }

                if track.count > 1 {
                    var path = Path()
                    path.move(to: spot(track[0]))
                    for p in track.dropFirst() { path.addLine(to: spot(p)) }
                    ctx.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    for (p, colour) in [(track[0], Color.green), (track[track.count - 1], Color.red)] {
                        let s = spot(p)
                        ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3.5, y: s.y - 3.5, width: 7, height: 7)), with: .color(colour))
                    }
                }

                for b in blips where b.id != lockedID {
                    let p = point(b, center: c, radius: R)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(b.orbit.color))
                    if arrived.contains(b.id) {
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)), with: .color(b.orbit.color.opacity(0.8)), lineWidth: 1)
                    }
                    if hovered?.id == b.id {
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)), with: .color(.white.opacity(0.9)), lineWidth: 1)
                    }
                }
                if let id = lockedID, let b = blips.first(where: { $0.id == id }) {
                    let p = point(b, center: c, radius: R)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(b.orbit.color))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 1)
                }

                for (text, x, y) in [("N", c.x, c.y - R - 6), ("S", c.x, c.y + R + 6), ("E", c.x + R + 6, c.y), ("W", c.x - R - 6, c.y)] {
                    ctx.draw(Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: x, y: y))
                }
            }
        }
        .contentShape(Circle())
        .onTapGesture { loc in
            if let best = nearest(loc) { onSelect(best.id) }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc): hovered = nearest(loc)
            case .ended: hovered = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let h = hovered, let sat = label(h.id) {
                RadarTooltip(sat: sat)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        // Centred over the blip, kept inside the scope's width.
                        -min(max(h.at.x - d.width / 2, -30), Self.size + 30 - d.width)
                    }
                    .alignmentGuide(.top) { d in
                        -(h.at.y > d.height + 12 ? h.at.y - d.height - 9 : h.at.y + 9)
                    }
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Sky plot of \(blips.count) satellites")
    }
}

/// The hover label over a blip: flag and name.
struct RadarTooltip: View {
    let sat: Satellite

    var body: some View {
        HStack(spacing: 6) {
            FlagView(iso: sat.countryISO, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(sat.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(sat.countryName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }
}
