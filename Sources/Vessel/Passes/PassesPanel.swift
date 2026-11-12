import SwiftUI
import AppKit

/// Upcoming passes of the locked satellite: a 48-hour timeline, then the list. Click one to draw it on the radar.
struct PassesSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var planner: PassPlanner

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if app.locked == nil {
                Text("Lock a satellite to see its passes.").foregroundStyle(.secondary)
            } else if app.station == nil {
                Text("Set your location to see passes over it.").foregroundStyle(.secondary)
            } else if planner.passes.isEmpty {
                Text(planner.isWorking ? "Working out passes…" : "No passes in the next 48 hours. Satellites that stay in view, like geostationary ones, have none.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                PassTimeline(passes: planner.passes, selected: planner.selected)
                    .frame(height: 34)
                VStack(spacing: 0) {
                    ForEach(planner.passes.prefix(12)) { p in
                        PassRow(pass: p, selected: planner.selected == p)
                            .contentShape(Rectangle())
                            .onTapGesture { planner.selected = planner.selected == p ? nil : p }
                    }
                }
                if planner.selected != nil {
                    Text("Shown on the radar: green is where it rises, red where it sets.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("Announce passes aloud", isOn: $planner.announce).controlSize(.small)
            if planner.announce {
                Stepper("Warn \(planner.minutesBefore) min before", value: $planner.minutesBefore, in: 0...10).controlSize(.small)
            }
            Stepper("Hide passes below \(Int(planner.minElevation))°", value: $planner.minElevation, in: 0...40, step: 5).controlSize(.small)
        }
        .font(.system(size: 11))
    }
}

private struct PassRow: View {
    let pass: SatPass
    let selected: Bool

    private var day: String {
        Calendar.current.isDateInToday(pass.aos) ? "Today" : Calendar.current.isDateInTomorrow(pass.aos) ? "Tomorrow"
            : pass.aos.formatted(.dateTime.weekday(.abbreviated))
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(pass.isUp() ? Color.green : Color.clear).frame(width: 6, height: 6)
            Text(day).frame(width: 58, alignment: .leading)
            Text("\(pass.aos.formatted(date: .omitted, time: .shortened))").monospacedDigit()
            Spacer(minLength: 2)
            Text("\(Int((pass.duration / 60).rounded())) min").foregroundStyle(.secondary).monospacedDigit()
            Text("\(Int(pass.maxElevation.rounded()))°").monospacedDigit().frame(width: 30, alignment: .trailing)
                .fontWeight(pass.maxElevation >= 30 ? .semibold : .regular)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .help("Rises \(pass.aos.formatted(date: .abbreviated, time: .standard)), sets \(pass.los.formatted(date: .omitted, time: .standard)), highest at \(Int(pass.maxElevation.rounded()))°")
    }
}

/// Each pass as a bar on a 48-hour strip, taller for higher passes.
private struct PassTimeline: View {
    let passes: [SatPass]
    let selected: SatPass?

    var body: some View {
        Canvas { ctx, size in
            let start = Date(), span = 48.0 * 3600
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.black.opacity(0.3)))
            for h in stride(from: 0.0, through: 48, by: 12) {
                let x = size.width * h / 48
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            }
            for p in passes {
                let x0 = size.width * max(0, p.aos.timeIntervalSince(start)) / span
                let x1 = size.width * min(span, p.los.timeIntervalSince(start)) / span
                guard x1 > 0, x0 < size.width else { continue }
                let h = max(3, (size.height - 4) * p.maxElevation / 90)
                let rect = CGRect(x: x0, y: size.height - 2 - h, width: max(2, x1 - x0), height: h)
                ctx.fill(Path(rect), with: .color(p == selected ? .accentColor : p.maxElevation >= 30 ? .green : .green.opacity(0.5)))
            }
            ctx.draw(Text("now").font(.system(size: 8)).foregroundStyle(.secondary), at: CGPoint(x: 3, y: 2), anchor: .topLeading)
            ctx.draw(Text("+48 h").font(.system(size: 8)).foregroundStyle(.secondary), at: CGPoint(x: size.width - 3, y: 2), anchor: .topTrailing)
        }
        .accessibilityLabel("Timeline of \(passes.count) passes in the next 48 hours")
    }
}

/// Finds when you and another station can both see the locked satellite.
struct ContactPlannerSection: View {
    @EnvironmentObject var app: AppState
    @AppStorage("planner.dxGrid") private var grid = ""
    @State private var windows: [MutualWindow] = []
    @State private var working = false
    @State private var searched = false

    private var target: (lat: Double, lon: Double)? { Maidenhead.coordinates(grid) }
    private struct Box: @unchecked Sendable { let sat: Satellite }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("When you and another station can both see this satellite.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Their grid, like JO62", text: $grid)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(find)
                Button("Find", action: find).controlSize(.small)
                    .disabled(target == nil || app.locked == nil || app.station == nil || working)
            }
            if !grid.isEmpty, target == nil {
                Text("Enter a 4- or 6-character grid square.").foregroundStyle(.orange)
            } else if app.locked == nil {
                Text("Lock a satellite first.").foregroundStyle(.secondary)
            } else if app.station == nil {
                Text("Set your own location first.").foregroundStyle(.secondary)
            } else if working {
                Text("Searching the next 7 days…").foregroundStyle(.secondary)
            } else if searched, windows.isEmpty {
                Text("No shared windows in the next 7 days. The two places may be too far apart for this orbit.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(windows.prefix(8)) { w in
                    HStack(spacing: 6) {
                        Text(w.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())).monospacedDigit()
                        Spacer(minLength: 2)
                        Text(Self.length(w)).foregroundStyle(.secondary).monospacedDigit()
                        Text("\(Int(w.maxElevationHere))° / \(Int(w.maxElevationThere))°").monospacedDigit()
                    }
                    .help("From \(w.start.formatted(date: .abbreviated, time: .standard)) to \(w.end.formatted(date: .omitted, time: .standard)). Highest for you \(Int(w.maxElevationHere))°, for them \(Int(w.maxElevationThere))°.")
                }
                if !windows.isEmpty {
                    Text("Start, length, and highest point for you / for them.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .onChange(of: app.locked?.norad) { _, _ in windows = []; searched = false }
    }

    static func length(_ w: MutualWindow) -> String {
        let s = Int(w.end.timeIntervalSince(w.start))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }

    private func find() {
        guard let t = target, let st = app.station, let copy = app.locked?.clone(), !working else { return }
        working = true
        let box = Box(sat: copy)
        Task.detached(priority: .userInitiated) {
            let found = PassPredictor.mutualWindows(box.sat, here: (st.lat, st.lon), there: t)
            await MainActor.run { windows = found; working = false; searched = true }
        }
    }
}

/// Logs a contact to an ADIF file that logging programs can import.
struct ContactLogSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var tx: TransmitController
    @State private var call = ""
    @State private var grid = ""
    @State private var sent = "59"
    @State private var received = "59"
    @State private var note: String?
    @State private var saved = 0

    private var file: URL { app.outputDir.appendingPathComponent("contacts.adi") }
    private var ready: Bool { Callsign.isValid(call.uppercased()) && app.locked != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Their callsign", text: $call).textFieldStyle(.roundedBorder).controlSize(.small)
                TextField("Grid", text: $grid).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 70)
            }
            HStack {
                Text("Sent").foregroundStyle(.secondary)
                TextField("59", text: $sent).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 46)
                Text("Received").foregroundStyle(.secondary)
                TextField("59", text: $received).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 46)
            }
            HStack {
                Button("Log contact", action: save).controlSize(.small).disabled(!ready)
                Spacer()
                if saved > 0 {
                    Button("\(saved) logged") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.link).help("Show the log file in Finder")
                }
            }
            if let note { Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            else if app.locked == nil { Text("Lock the satellite you're working through.").foregroundStyle(.secondary) }
        }
        .font(.system(size: 11))
        .onAppear { saved = ADIF.count(in: file) }
    }

    private func save() {
        guard let sat = app.locked else { return }
        let myGrid = app.station.flatMap { $0.fromSpyHost ? nil : Maidenhead.locator(lat: $0.lat, lon: $0.lon) } ?? ""
        let c = ADIF.Contact(date: Date(), call: call, grid: grid, sent: sent, received: received, satellite: sat.name,
                             mode: tx.mode?.rawValue ?? tx.uplink?.modeName ?? "FM",
                             uplinkHz: tx.uplink?.lowHz, downlinkHz: tx.uplink?.downlinkLowHz ?? app.frequency,
                             myCall: tx.callsign, myGrid: myGrid)
        do {
            try ADIF.append(c, to: file)
            saved = ADIF.count(in: file)
            note = "Logged \(call.uppercased()) at \(Date().formatted(date: .omitted, time: .shortened))."
            call = ""; grid = ""
        } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
