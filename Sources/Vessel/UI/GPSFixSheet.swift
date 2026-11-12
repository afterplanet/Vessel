import AppKit
import MapKit
import SwiftUI

/// The popup offered when there's no Wi-Fi to find a location with, which then does the whole job.
struct GPSFixSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner
    @StateObject private var controller = GPSFixController()
    let offer: GPSOffer

    @State private var seconds = GPSFixPlan.defaultDuration
    private let gnssSDR = GPSFixPlan.findGNSSSDR()
    @State private var online = true

    private var receiver: GPSFixPlan.Receiver { app.gpsReceiver }

    /// What's connected in Listener, as you'd recognise it.
    private var connectedName: String {
        if app.source.addressFlag != nil, !app.address.isEmpty {
            return "\(app.source.name) at \(app.address)" + (app.source.defaultPort != nil ? ":\(app.port)" : "")
        }
        return app.connectedDevice ?? app.source.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsIntro { header }
            switch controller.stage {
            case .ready: ask
            case .recording(let elapsed, let total): recording(elapsed, total)
            case .processing(let satellites, let positioned): processing(satellites, positioned)
            case .found(let fix): found(fix)
            case .failed(let message): failed(message)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: showRequestedScreen)
        .interactiveDismissDisabled(controller.isBusy)
    }

    /// `--gps-result good|few|failed` opens a screen directly, for checking how it looks.
    private func showRequestedScreen() {
        let a = Snapshot.arguments
        guard let i = a.firstIndex(of: "--gps-result"), a.indices.contains(i + 1) else { return }
        switch a[i + 1] {
        case "few":
            controller.show(.found(GPSFixPlan.Fix(latitude: 41.27484, longitude: 1.98769, height: 74, spread: 240, readings: 18, satellitesUsed: 4, satellitesHeard: 5)))
        case "failed":
            controller.show(.failed("Heard 2 satellites, but a position needs \(GPSFixPlan.minimumSatellites) with a clean signal for long enough. Try a longer recording with a clearer view of the sky."), heard: 2)
        default:
            controller.show(.found(GPSFixPlan.Fix(latitude: 41.27484, longitude: 1.98769, height: 74, spread: 5.4, readings: 510, satellitesUsed: 6, satellitesHeard: 7)))
        }
    }

    /// Once there's a result, that's all this needs to show.
    private var showsIntro: Bool {
        switch controller.stage {
        case .found, .failed: false
        default: true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "location.north.circle.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.reason).font(.system(size: 14, weight: .semibold))
                Text("Vessel can work out your position from GPS satellites with your receiver. It takes a few minutes and needs no internet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Asking

    @ViewBuilder private var ask: some View {
        switch app.gpsReadiness {
        case .ready: setup
        case .needsSource(let message):
            notice(message, symbol: "antenna.radiowaves.left.and.right.slash")
        }
        if gnssSDR == nil {
            notice("This copy of Vessel was built without its GPS processor.", symbol: "exclamationmark.triangle.fill")
        }
        if runner.isRunning {
            notice("A capture is using the receiver. Stop it first.", symbol: "exclamationmark.triangle.fill")
        }
        HStack {
            if offer.canUseInternet {
                Button("Use Internet Address") {
                    app.gpsOffer = nil
                    app.findFromInternetAddress()
                }
            }
            Spacer()
            Button("Not Now", role: .cancel) { app.gpsOffer = nil }.keyboardShortcut(.cancelAction)
            Button("Scan GPS Satellites") {
                controller.start(receiver, seconds: seconds, engine: runner.executable, gnssSDR: gnssSDR, engineFolder: PipelineUpdater.runDir)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(gnssSDR == nil || runner.isRunning || app.gpsReadiness != .ready)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 9) {
            setupRow("Receiver") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    Text(connectedName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .help("The source chosen in Listener")
            }
            setupRow("Recording") {
                Picker("", selection: $seconds) {
                    Text("2 minutes").tag(120)
                    Text("5 minutes, for a weak signal").tag(300)
                }
                .labelsHidden().controlSize(.small)
            }
            if app.source.hasBias {
                setupRow("Antenna") {
                    Toggle("Power an active antenna (bias tee)", isOn: $app.bias).controlSize(.small).font(.system(size: 12))
                }
            }
            Text("Put a GPS antenna where it can see open sky. This briefly uses \(ByteCountFormatter.string(fromByteCount: Int64(GPSFixPlan.recordingBytes(rate: receiver.sampleRate, seconds: seconds)), countStyle: .file)) of disk, deleted afterwards.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Working

    private func recording(_ elapsed: Int, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Recording GPS signals", detail: "\(remaining(total - elapsed)) left")
            ProgressView(value: Double(elapsed), total: Double(max(total, 1)))
            step(2, "Working out your position", detail: nil, active: false)
            cancelRow
        }
    }

    private func processing(_ satellites: Int, _ positioned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Recorded GPS signals", detail: nil, done: true)
            step(2, "Working out your position",
                 detail: positioned ? "Position found, finishing up" : satellites > 0 ? "\(satellites) satellite\(satellites == 1 ? "" : "s") heard so far" : "Looking for satellites")
            ProgressView()
            cancelRow
        }
    }

    private var cancelRow: some View {
        HStack {
            Text("Keep this window open.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                controller.cancel()
                app.gpsOffer = nil
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func step(_ number: Int, _ title: String, detail: String?, active: Bool = true, done: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle.fill")
                .foregroundStyle(done ? Color.green : active ? Color.accentColor : Color.secondary)
            Text(title).font(.system(size: 12, weight: active ? .medium : .regular)).foregroundStyle(active ? Color.primary : Color.secondary)
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    private func remaining(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(seconds, 0) / 60, max(seconds, 0) % 60)
    }

    // MARK: Results

    private func found(_ fix: GPSFixPlan.Fix) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        let text = SavedLocation.coordinates(latitude: fix.latitude, longitude: fix.longitude)
        return VStack(alignment: .leading, spacing: 10) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                Marker("Your position", coordinate: coordinate)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .overlay(alignment: .bottomLeading) {
                if !online {
                    Text("The map needs internet. The position is right without it.")
                        .font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5)).padding(6)
                }
            }
            HStack(spacing: 8) {
                Text(text).font(.system(size: 15, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy the latitude and longitude").accessibilityLabel("Copy")
                if online, let url = SavedLocation.googleMapsURL(latitude: fix.latitude, longitude: fix.longitude) {
                    Button("Open in Google Maps") { NSWorkspace.shared.open(url) }
                }
            }
            .controlSize(.small)
            HStack(spacing: 14) {
                measure("Latitude", String(format: "%.5f°", fix.latitude))
                measure("Longitude", String(format: "%.5f°", fix.longitude))
                measure("Satellites", satellitesText(fix))
                measure("Accuracy", LocationNote.within(max(fix.spread, 5)).replacingOccurrences(of: "within about ", with: "± "))
            }
            ForEach(fix.warnings, id: \.self) { notice($0, symbol: "exclamationmark.triangle.fill") }
            HStack {
                Button("Scan Again") { controller.reset() }
                Spacer()
                Button("Discard", role: .cancel) { app.gpsOffer = nil }.keyboardShortcut(.cancelAction)
                Button("Pin Location") { app.useGPSFix(fix) }.keyboardShortcut(.defaultAction)
            }
        }
        .task { online = await NetworkStatus.check().internet }
    }

    private func satellitesText(_ fix: GPSFixPlan.Fix) -> String {
        switch (fix.satellitesUsed, fix.satellitesHeard) {
        case let (used?, heard?) where heard > used: "\(used) used of \(heard)"
        case let (used?, _): "\(used)"
        case let (nil, heard?): "\(heard) heard"
        default: "Unknown"
        }
    }

    private func measure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).monospacedDigit().lineLimit(1)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No position found", systemImage: "location.slash.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            HStack(spacing: 8) {
                Text("Satellites").font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView(value: Double(min(controller.satellitesHeard, GPSFixPlan.minimumSatellites)), total: Double(GPSFixPlan.minimumSatellites))
                    .tint(controller.satellitesHeard >= GPSFixPlan.minimumSatellites ? Color.green : Color.orange)
                Text("\(controller.satellitesHeard) heard, \(GPSFixPlan.minimumSatellites) needed")
                    .font(.system(size: 11)).monospacedDigit().fixedSize()
            }
            notice(message, symbol: "exclamationmark.triangle.fill")
            if let detail = controller.failureDetail {
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { app.gpsOffer = nil }.keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    seconds = 300
                    controller.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
    }

    private func setupRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
