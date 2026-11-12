import SwiftUI

/// What operators have been reporting about the locked satellite, and a way to add your own.
struct AMSATPanel: View {
    let satellite: Satellite
    @EnvironmentObject var app: AppState
    @EnvironmentObject var tx: TransmitController
    @StateObject private var status = AMSATStatus()
    @State private var reportMode: String?
    @State private var pending: AMSATAPI.Observation?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("AMSAT reports").font(.system(size: 11, weight: .semibold))
                if status.isLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Link(destination: AMSATAPI.site) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help("Open AMSAT's status page")
            }
            if status.modes.isEmpty {
                Text(status.isLoading ? "Checking…" : "AMSAT doesn't track this satellite.").foregroundStyle(.secondary)
            } else {
                // Quiet modes would bury the ones people are using: the ISS alone lists six.
                let reported = status.modes.filter { $0.latest != nil }
                ForEach(reported.isEmpty ? status.modes : reported) { modeRow($0) }
                if !reported.isEmpty, reported.count < status.modes.count {
                    let quiet = status.modes.count - reported.count
                    Text("\(quiet) more \(quiet == 1 ? "mode" : "modes") with no reports in the last 24 hours")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !status.recent.isEmpty { recentReports }
                reportControls
            }
            footer
        }
        // A new satellite starts clean. The wait keeps to AMSAT's polling limit, and stops with this page.
        .task(id: satellite.norad) {
            reportMode = nil
            status.sentMessage = nil
            while !Task.isCancelled {
                let wait = await status.refresh(name: satellite.name, norad: satellite.norad)
                try? await Task.sleep(for: .seconds(wait + 1))
            }
        }
    }

    private func color(_ report: String?) -> Color {
        switch report {
        case "Heard", "Crew Active": .green
        case "Telemetry Only": .yellow
        case "Not Heard": .red
        default: Color.secondary.opacity(0.4)
        }
    }

    private func word(_ report: String?) -> String {
        switch report {
        case "Heard": "Active"
        case "Telemetry Only": "Beacon only"
        case "Not Heard": "Not heard"
        case "Crew Active": "Crew active"
        default: report ?? "No reports"
        }
    }

    private func modeRow(_ m: AMSATAPI.ModeStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color(m.latestReport)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.display).fontWeight(.medium)
                if let latest = m.latest {
                    (Text("\(word(m.latestReport)), ") + Text(latest, style: .relative) + Text(" ago"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(counts(m)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("No reports in the last 24 hours").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func counts(_ m: AMSATAPI.ModeStatus) -> String {
        ["Heard", "Crew Active", "Telemetry Only", "Not Heard"].compactMap { key in
            m.counts[key].map { "\($0) \(word(key).lowercased())" }
        }.joined(separator: " · ")
    }

    private var recentReports: some View {
        DisclosureGroup("Latest reports") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(status.recent) { r in
                    HStack(spacing: 5) {
                        Circle().fill(color(r.report)).frame(width: 5, height: 5)
                        Text(r.callsign).fontWeight(.medium)
                        if let grid = r.grid_square, !grid.isEmpty { Text(grid).foregroundStyle(.secondary) }
                        Spacer(minLength: 2)
                        if let d = r.date { Text(d, style: .relative).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .font(.system(size: 10))
                    .help("\(r.name.replacingOccurrences(of: "_", with: " ")): \(word(r.report))")
                }
            }
            .padding(.top, 2)
        }
        .font(.system(size: 11))
    }

    // MARK: Reporting

    private var chosenMode: AMSATAPI.ModeStatus? {
        status.modes.first { $0.name == reportMode } ?? status.modes.first
    }

    /// Only the operator's own location, never a public host's that the address bar is borrowing.
    private var grid: String? {
        app.station.flatMap { $0.fromSpyHost ? nil : Maidenhead.locator(lat: $0.lat, lon: $0.lon) }
    }

    private var reportProblem: String? {
        Callsign.isValid(tx.callsign) ? nil : "Enter your callsign below to send a report"
    }

    private var reportControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.modes.count > 1 {
                Picker("", selection: Binding(get: { chosenMode?.name ?? "" }, set: { reportMode = $0 })) {
                    ForEach(status.modes) { Text($0.display).tag($0.name) }
                }
                .labelsHidden().controlSize(.small)
            }
            HStack(spacing: 4) {
                Text("You heard:").foregroundStyle(.secondary).fixedSize()
                ForEach(AMSATAPI.Observation.allCases) { o in
                    Button(o.label) { pending = o }.controlSize(.small)
                }
            }
            .disabled(reportProblem != nil || status.sending)
            .help(reportProblem ?? "Tell other operators what you heard. Nothing is sent until you confirm.")
            if let problem = reportProblem {
                Text(problem).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let message = status.sentMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Send this public report to AMSAT?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("Send report") {
                guard let observation = pending, let mode = chosenMode else { return }
                pending = nil
                Task {
                    await status.submit(mode: mode, observation: observation, callsign: tx.callsign, grid: grid,
                                        satellite: satellite.name, norad: satellite.norad)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(confirmation)
        }
    }

    private var confirmation: String {
        let call = tx.callsign.split(separator: "-").first.map(String.init) ?? tx.callsign
        let clock = DateFormatter()
        clock.timeZone = TimeZone(identifier: "UTC")
        clock.dateFormat = "HH:mm"
        let when = clock.string(from: Date())
        let mode = chosenMode?.display ?? ""
        return "\(mode): \(pending?.label ?? "")\nCallsign \(call)\nGrid \(grid ?? "not included")\nTime \(when) UTC\n\nOnly send what you really observed yourself. It appears publicly on AMSAT's status page."
    }

    private var footer: some View {
        Group {
            if status.failed {
                Text("AMSAT couldn't be reached, so this may be out of date.").foregroundStyle(.orange)
            } else if let updated = status.updated {
                Text("Updated ") + Text(updated, style: .relative) + Text(" ago. Data: AMSAT, CC BY 4.0.")
            } else {
                Text("Data: AMSAT, CC BY 4.0.")
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
