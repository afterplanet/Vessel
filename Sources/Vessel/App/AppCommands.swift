import SwiftUI

/// The menu bar. Everything here does what a control in the window does, and keys nothing:
/// transmitting stays on the hold-to-talk button.
struct AppCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var runner: SatDumpRunner
    @ObservedObject var tx: TransmitController
    @ObservedObject var rotator: RotatorController
    @ObservedObject var store: SatelliteStore
    @ObservedObject var updates: DataUpdates
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("Show Results") { openWindow(id: "results") }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open Capture Folder") { NSWorkspace.shared.open(runner.outputDir ?? app.outputDir) }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .importExport) {}

        // MARK: View
        CommandGroup(replacing: .sidebar) {
            Button("Receiver") { app.panelMode = .receive }.keyboardShortcut("1", modifiers: .command)
            Button("Transmitter") { app.panelMode = .transmit }.keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Toggle Sidebar") { app.toggleSidebarRequest += 1 }.keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Spectrum", isOn: $app.showSpectrum).keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Button("Filters…") { app.showFilters = true }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("Clear Filters") { app.satelliteFilter = SatelliteFilter() }.disabled(!app.satelliteFilter.isActive)
            Picker("Orbit", selection: $app.orbitFilter) {
                Text("All Orbits").tag(OrbitClass?.none)
                ForEach(OrbitClass.allCases) { Text($0.title).tag(Optional($0)) }
            }
        }

        // MARK: Satellite
        CommandMenu("Satellite") {
            if let sat = app.locked {
                Text(sat.name)
                Divider()
            }
            Toggle("Follow on Globe", isOn: $app.followLocked).disabled(app.locked == nil)
            Button("Scan for Its Signal…") { app.showScan = true }.disabled(app.locked == nil || app.scanSourceProblem != nil)
            Button("Stations That Can Hear It") {
                app.panelMode = .receive
                app.hostsForSatellite = true
            }
            .disabled(app.source.kind != .spy)
            Menu("Spacecraft") {
                ForEach(SpaceObject.Kind.allCases) { kind in
                    Section(kind.rawValue) {
                        ForEach(SpaceCatalog.of(kind: kind)) { o in
                            Button(o.name) { app.openSpaceObject(o, store: store) }
                        }
                    }
                }
            }
            if app.spaceObject != nil { Button("Back to Earth") { app.closeSpaceObject() } }
            Divider()
            Button("Unlock") { app.unlock() }.keyboardShortcut("u", modifiers: .command).disabled(app.locked == nil)
        }

        // MARK: Capture
        CommandMenu("Capture") {
            if runner.isRunning {
                Button("Stop") { app.stopCapture() }.keyboardShortcut("l", modifiers: .command)
            } else {
                Button("Start Listening") { app.startListening() }.keyboardShortcut("l", modifiers: .command)
                    .disabled(!app.canStartListening)
            }
            Divider()
            Picker("Output", selection: $app.listenOutput) {
                ForEach(ListenOutput.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(runner.isRunning)
            Toggle("Play Through Speaker", isOn: $app.speakerOn).keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(app.speakerProblem != nil)
            Divider()
            Button("Antenna Rotator…") {
                app.panelMode = .receive
                app.showSidebarRequest += 1
                rotator.showSettings = true
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!app.supportsRotator)
            Button("Stop Rotator") { rotator.stop() }.keyboardShortcut(".", modifiers: [.command, .shift]).disabled(!rotator.isConnected)
        }

        // MARK: Transmit
        CommandMenu("Transmit") {
            Picker("Radio", selection: $tx.radioKind) {
                ForEach(RadioKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(tx.isRadioConnected)
            Button(tx.isRadioConnected ? "Disconnect Radio" : "Connect Radio") {
                app.panelMode = .transmit
                tx.isRadioConnected ? tx.disconnect() : tx.connect()
            }
            Button("Look for a Radio on USB") { tx.searchForRadios(force: true) }
                .disabled(tx.isRadioConnected || tx.isSearchingForRadio)
        }

        // MARK: Data
        CommandMenu("Data") {
            Text(orbitsLine)
            Divider()
            Button("Check for Updates Now") {
                Task { await updates.checkNow(store: store, app: app, runner: runner) }
            }
            .disabled(updates.isChecking)
            Button("Data Updates…") { openWindow(id: "data") }
            Divider()
            Button("Refresh Spy Hosts") { Task { await app.refreshHosts() } }
        }

        // MARK: Help
        CommandGroup(replacing: .help) {
            Link("AMSAT Satellite Status", destination: AMSATAPI.site)
            Link("SatNOGS Database", destination: URL(string: "https://db.satnogs.org")!)
            Link("CelesTrak Orbit Data", destination: URL(string: "https://celestrak.org")!)
            Link("Hamlib (Radio and Rotator Control)", destination: URL(string: "https://hamlib.github.io")!)
        }
    }

    private var orbitsLine: String {
        _ = updates.refreshTick
        return DataUpdates.age(of: "gp_active.json").map { "Orbits updated \(DataUpdates.words(age: $0))" } ?? "Orbits not downloaded yet"
    }
}
