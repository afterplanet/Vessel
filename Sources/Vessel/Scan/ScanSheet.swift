import SwiftUI

/// The search for a satellite's unlisted downlink: a live waterfall to click on, and the
/// signals found so far, tested against the satellite's Doppler.
struct ScanSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner
    @StateObject private var scanner = FrequencyScanner()
    let satellite: Satellite
    @State private var bands: Set<ScanBand>
    @State private var marked: Double?
    @Environment(\.dismiss) private var dismiss

    init(satellite: Satellite) {
        self.satellite = satellite
        _bands = State(initialValue: Set(ScanBand.likely(for: satellite.category)))
    }

    private var host: SpyHost? { app.source.kind == .spy && !app.source.browserOnly ? app.selectedHost : nil }
    private var source: ScanSource? { app.scanSource() }
    /// A public host's range is checked against the host. Your own receiver's is known here.
    private var ownRanges: [ClosedRange<Double>]? { app.source.kind == .spy ? nil : app.receiverRanges }
    private var chosen: [ScanBand] { ScanBand.all.filter { bands.contains($0) && $0.isReachable(by: ownRanges) } }
    private var best: (host: SpyHost, elevation: Double)? {
        ScanHosts.best(app.hosts.filter { app.status(of: $0) != .dead && !$0.isFull }, satellite: satellite, bands: chosen)
    }

    private var startProblem: String? {
        if runner.isRunning { return "Stop listening first, because scanning needs the same receiver." }
        if chosen.isEmpty { return "Choose at least one band." }
        if app.station == nil { return "Set a location in the address bar, so the scan knows where the satellite is." }
        if let problem = app.scanSourceProblem { return problem }
        if let host, !chosen.contains(where: { $0.reachable(minHz: host.minHz, maxHz: host.maxHz) }) { return "This host can't reach the chosen bands." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !scanner.isRunning { setup }
            waterfall
            status
            results
            footer
        }
        .padding(16)
        .frame(width: 720)
        .frame(minHeight: 620)
        .onDisappear { scanner.stop() }
        .onAppear {
            if Snapshot.arguments.contains("--scan-autostart") { start() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scan for \(satellite.name)").font(.system(size: 15, weight: .semibold))
            Text("Listens across likely bands for signals, then checks each against the Doppler shift this satellite's orbit predicts. It only listens.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 3) {
                ForEach(ScanBand.all) { b in
                    Toggle(b.name, isOn: Binding(
                        get: { bands.contains(b) },
                        set: { if $0 { bands.insert(b) } else { bands.remove(b) } }
                    ))
                    .font(.system(size: 11)).controlSize(.small)
                    .disabled(!b.isReachable(by: ownRanges))
                    .help(b.isReachable(by: ownRanges) ? "" : "Outside \(app.source.name)'s range")
                }
            }
            HStack(spacing: 8) {
                Text("Through").font(.system(size: 11)).foregroundStyle(.secondary)
                if let host {
                    FlagView(iso: host.iso, height: 11)
                    Text(host.shortName).font(.system(size: 11)).lineLimit(1)
                } else {
                    Text(app.source.name).font(.system(size: 11)).lineLimit(1)
                }
                Group {
                    if let el = app.elevation {
                        Text(String(format: "elevation %.0f°", el)).font(.system(size: 11))
                            .foregroundStyle(el > 0 ? Color.green : Color.orange).monospacedDigit()
                    }
                }
                Spacer()
                if app.source.kind == .spy, let b = best, b.host.id != host?.id {
                    Button("Use \(b.host.shortName), satellite at \(Int(b.elevation))°") { app.selectHost(b.host) }
                        .controlSize(.small).lineLimit(1)
                        .help("A working host that can see this satellite right now")
                }
            }
            if let e = app.elevation, e <= 0, app.source.kind != .spy || best == nil {
                Label(nextPassText, systemImage: "clock").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let p = startProblem {
                Label(p, systemImage: "info.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nextPassText: String {
        if case .pass(let p) = app.pass, p.aos > Date() {
            return "Below the horizon here, so nothing heard could be this satellite. It rises at \(p.aos.formatted(date: .omitted, time: .shortened))."
        }
        return "Below the horizon here, so nothing heard could be this satellite."
    }

    private var shown: ScanWindow? { scanner.viewing ?? scanner.current }

    private var waterfall: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black)
                    if let picture = scanner.picture {
                        Image(decorative: picture, scale: 1).resizable().interpolation(.none)
                    } else {
                        Text(scanner.isRunning ? "Waiting for the host…" : "The waterfall appears here. Click a bright streak to mark its frequency.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let w = shown, let m = marked, m >= w.lowHz, m <= w.highHz {
                        Rectangle().fill(.yellow).frame(width: 1)
                            .offset(x: CGFloat((m - w.lowHz) / w.spanHz) * g.size.width)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { t in
                    if let w = shown { marked = w.lowHz + Double(t.location.x / g.size.width) * w.spanHz }
                })
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack {
                if let w = shown {
                    Text(ScanWords.hz(w.lowHz))
                    Spacer()
                    Picker("", selection: Binding(get: { scanner.viewing }, set: { scanner.show($0) })) {
                        Text("Following the sweep").tag(ScanWindow?.none)
                        ForEach(scanner.windows) { Text(ScanWords.hz($0.centerHz)).tag(Optional($0)) }
                    }
                    .labelsHidden().controlSize(.mini).frame(width: 170)
                    Spacer()
                    Text(ScanWords.hz(w.highHz))
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var status: some View {
        switch scanner.state {
        case .idle: EmptyView()
        case .connecting: Text("Connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .scanning:
            let e = scanner.elevation.map { String(format: ", satellite at %.0f°", $0) } ?? ""
            Text("Sweep \(scanner.sweeps + 1) of \(scanner.windows.count) windows\(e). \(app.source.kind == .spy ? "Doppler needs a minute or two to show." : "This radio restarts for each window, so sweeps take a while.")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .stopped: Text("Stopped.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let m): Label(m, systemImage: "xmark.octagon.fill").font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let m = marked {
                row(hz: m, title: "Marked on the waterfall", detail: "Your choice", color: .yellow)
                Divider()
            }
            Text(scanner.candidates.isEmpty ? "Signals found: none yet" : "Signals found").font(.system(size: 11, weight: .medium))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(scanner.candidates.prefix(30)) { c in
                        row(hz: c.restHz, title: c.verdict.title,
                            detail: String(format: "+%.0f dB, %.1f kHz wide, seen %d times", c.strengthDB, c.widthHz / 1000, c.sightings),
                            color: color(c.verdict))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func color(_ v: ScanVerdict) -> Color {
        switch v {
        case .dopplerMatch: .green
        case .undetermined: .yellow
        case .otherMover, .fixed: .secondary
        }
    }

    private func row(hz: Double, title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(color).frame(width: 3, height: 22)
            Text(ScanWords.hz(hz)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Use") {
                app.useScannedFrequency(hz, for: satellite)
                dismiss()
            }
            .controlSize(.small)
            .help("Tune to this frequency for this satellite. Nothing confirms it's really the satellite until it decodes.")
        }
        .contentShape(Rectangle())
    }

    private func start() {
        guard let source, let st = app.station else { return }
        marked = nil
        scanner.start(source: source, bands: chosen, satellite: satellite, station: st)
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if scanner.isRunning {
                Button("Stop scan") { scanner.stop() }
            } else {
                Button(scanner.sweeps > 0 ? "Scan again" : "Start scan") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(startProblem != nil || app.station == nil)
            }
        }
    }
}
