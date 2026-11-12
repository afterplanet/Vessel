import SwiftUI

/// One line of the startup checklist.
struct StartupStep: Identifiable, Equatable {
    enum State: Equatable {
        case working
        case done(String)
        /// Something is missing or failed. The app still opens, and this says what won't work.
        case problem(String)
        /// Still going after the wait limit. It carries on in the background.
        case slow(String)
    }
    let id: String
    let title: String
    let symbol: String
    var state: State

    var isFinished: Bool { if case .working = state { return false } else { return true } }
    var isProblem: Bool { if case .problem = state { return true } else { return false } }
}

/// What the startup checklist shows, worked out from what each part of the app has published.
/// Kept apart from the view so it can be tested.
struct StartupStatus: Equatable {
    var catalogueLoaded = false
    var catalogueCount = 0
    var catalogueError: String?
    var frequenciesLoaded = false
    var withFrequencies = 0
    var decodersChecked = false
    var decoderCount = 0
    var engineFound = false
    var engineProbed = false
    var gpsEngineFound = false
    var hardware: [String] = []
    var hardwareChecked = false
    var hostsLoaded = false
    var hostCount = 0
    /// Seconds since launch, after which anything still loading is left to finish in the background.
    var elapsed: TimeInterval = 0

    static let waitLimit: TimeInterval = 45

    var steps: [StartupStep] {
        let late = elapsed >= Self.waitLimit
        func pending(_ text: String = "Still loading. It will finish in the background.") -> StartupStep.State {
            late ? .slow(text) : .working
        }
        var list: [StartupStep] = []
        list.append(StartupStep(id: "catalogue", title: "Satellite catalogue", symbol: "globe",
            state: catalogueError.map { .problem("Couldn't load it: \($0). Check your internet connection.") }
                ?? (catalogueLoaded ? .done("\(catalogueCount.formatted()) satellites") : pending())))
        list.append(StartupStep(id: "frequencies", title: "Frequencies and satellite details", symbol: "list.bullet.rectangle",
            state: frequenciesLoaded ? .done("\(withFrequencies.formatted()) with listed frequencies")
                : catalogueError != nil ? .problem("Needs the satellite catalogue first.") : pending()))
        list.append(StartupStep(id: "engine", title: "Receiving engine", symbol: "waveform",
            state: !engineFound ? .problem("Missing from this copy of Vessel, so receiving won't work. Download Vessel again.")
                : engineProbed ? .done("Ready") : pending("Still starting. It will finish in the background.")))
        list.append(StartupStep(id: "decoders", title: "Decoders", symbol: "square.stack.3d.up",
            state: !engineFound ? .problem("Need the receiving engine.")
                : decodersChecked ? .done("\(decoderCount.formatted()) available") : pending()))
        list.append(StartupStep(id: "hardware", title: "Radio hardware", symbol: "cable.connector",
            state: hardwareChecked
                ? .done(hardware.isEmpty ? "None plugged in. You can still listen through online receivers." : hardware.joined(separator: ", "))
                : pending("Still looking. Plug-in radios will appear as they're found.")))
        list.append(StartupStep(id: "hosts", title: "Online receivers", symbol: "network",
            state: hostsLoaded ? (hostCount > 0 ? .done("\(hostCount.formatted()) stations") : .problem("The directory didn't answer. Online receivers won't be listed."))
                : pending()))
        list.append(StartupStep(id: "gps", title: "GPS positioning", symbol: "location",
            state: gpsEngineFound ? .done("Ready") : .problem("Not included in this build, so scanning GPS satellites for your position won't work.")))
        return list
    }

    var allFinished: Bool { steps.allSatisfy(\.isFinished) }
    var hasProblem: Bool { steps.contains(where: \.isProblem) }
}

/// Shown over the app while it starts: each part it needs, ticked off as it's ready.
/// It closes by itself once everything is ready, and stays open if anything is wrong, until dismissed.
struct StartupChecklist: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore
    @EnvironmentObject var runner: SatDumpRunner
    @Binding var isPresented: Bool
    @State private var started = Date()
    @State private var now = Date()
    @State private var gpsEngineFound = GPSFixPlan.findGNSSSDR() != nil

    private var status: StartupStatus {
        StartupStatus(
            catalogueLoaded: store.catalogVersion > 0, catalogueCount: store.satellites.count,
            catalogueError: store.status.hasPrefix("Could not") ? store.status.replacingOccurrences(of: "Could not load satellites: ", with: "") : nil,
            frequenciesLoaded: store.enrichmentVersion > 0, withFrequencies: store.satellites.lazy.filter { !$0.transmitters.isEmpty }.count,
            decodersChecked: runner.pipelinesChecked, decoderCount: runner.catalog.pipelines.count,
            engineFound: runner.executable != nil, engineProbed: runner.probedOnce,
            gpsEngineFound: gpsEngineFound,
            hardware: app.attachedHardware.map(\.title), hardwareChecked: runner.probedOnce || runner.executable == nil,
            hostsLoaded: app.hostsLoaded, hostCount: app.hosts.count,
            elapsed: now.timeIntervalSince(started))
    }

    var body: some View {
        let s = status
        ZStack {
            Rectangle().fill(.black.opacity(0.55)).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Getting Vessel ready").font(.system(size: 16, weight: .semibold))
                        Text(s.allFinished ? (s.hasProblem ? "Some parts need attention" : "Everything is ready")
                             : "Loading what Vessel needs. The first launch takes longest.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(s.steps) { row($0) }
                }
                HStack {
                    Spacer()
                    Button(s.allFinished ? "Continue" : "Skip") { close() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(22)
            .frame(width: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
            }
        }
        .onChange(of: s.allFinished && !s.hasProblem) { _, ready in
            guard ready else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                close()
            }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.25)) { isPresented = false }
    }

    private func row(_ step: StartupStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.system(size: 12, weight: .medium))
                switch step.state {
                case .working: Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .done(let t), .slow(let t): Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .problem(let t): Text(t).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Group {
                switch step.state {
                case .working: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .slow: Image(systemName: "clock").foregroundStyle(.secondary)
                case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 14))
            .frame(width: 18, height: 18)
        }
    }
}
