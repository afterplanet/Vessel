import SwiftUI
import AppKit

/// Reports raw mouse down and up. A SwiftUI gesture can end without telling anyone if the
/// view goes away, which is not acceptable for something holding a transmitter on.
final class HoldNSView: NSView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var held = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        held = true
        onPress?()
    }

    override func mouseUp(with event: NSEvent) { end() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { end() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func end() {
        guard held else { return }
        held = false
        onRelease?()
    }
}

private struct HoldArea: NSViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeNSView(context: Context) -> HoldNSView { HoldNSView() }
    func updateNSView(_ v: HoldNSView, context: Context) {
        v.onPress = onPress
        v.onRelease = onRelease
    }
}

struct TransmitSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var tx: TransmitController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            target
            if let sat = app.locked {
                if !sat.mediaKinds.isEmpty { Divider(); pictures(sat) }
                Divider()
                AMSATPanel(satellite: sat)
            }
            Divider()
            station
            radio
            Divider()
            checklist
            holdButton
            status
        }
        .font(.system(size: 11))
        .task {
            // For checking the position controls without clicking through them.
            guard Snapshot.arguments.contains("--tx-position") else { return }
            try? await Task.sleep(for: .seconds(4))
            tx.uplink = tx.uplinks.first { $0.modes.contains(.aprsPosition) }
            tx.mode = .aprsPosition
        }
    }

    // MARK: Target

    @ViewBuilder private var target: some View {
        if let sat = app.locked {
            if tx.uplinks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Receive only", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11, weight: .semibold))
                    if UplinkPolicy.refused(for: sat).isEmpty {
                        Text(receiveOnlyReason(sat)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                uplinkControls
            }
            RefusedUplinkList(satellite: sat)
        } else {
            Text("Lock a satellite to see its public uplinks.").foregroundStyle(.secondary)
        }
    }

    /// Pictures only come down: it's worth knowing they're there, and a quick way over to listen.
    private func pictures(_ sat: Satellite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Listen: pictures from this satellite").font(.system(size: 11, weight: .semibold))
            MediaSignalList(satellite: sat, disabled: tx.isPressing, action: "Listen") { signal in
                app.tuneMedia(signal)
                app.panelMode = .receive
            }
            Text("Receive only. Vessel doesn't send pictures or video.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func receiveOnlyReason(_ sat: Satellite) -> String {
        let withUplink = sat.transmitters.filter { $0.uplinkLowHz != nil }
        if let first = withUplink.first {
            return "\(UplinkPolicy.evaluate(first).reason). Only public amateur uplinks can be transmitted to."
        }
        return "No public amateur uplink is listed for this satellite."
    }

    private var uplinkControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Uplink") {
                Picker("", selection: $tx.uplink) {
                    ForEach(tx.uplinks) { u in Text(u.description).tag(Optional(u)) }
                }
                .labelsHidden().controlSize(.small).disabled(tx.isPressing)
            }
            row("Mode") {
                if let u = tx.uplink, !u.modes.isEmpty {
                    Picker("", selection: $tx.mode) {
                        ForEach(u.modes) { m in Text(m.rawValue).tag(Optional(m)) }
                    }
                    .labelsHidden().controlSize(.small).disabled(tx.isPressing)
                } else {
                    Text("\(tx.uplink?.modeName ?? "This mode") isn't supported yet").foregroundStyle(.secondary)
                }
            }
            if let u = tx.uplink, u.isLinear {
                row("Passband") {
                    Slider(value: $tx.passbandPosition, in: 0...1).controlSize(.small).disabled(tx.isPressing)
                }
            }
            if let u = tx.uplink {
                row("Sends on") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mhz(tx.signalHz ?? u.signalHz(position: tx.passbandPosition, mode: tx.mode))).monospacedDigit().fontWeight(.medium)
                        Text(detailLine(u)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let rx = tx.rxHz { row("Hears on") { Text(mhz(rx)).monospacedDigit() } }
            }
            if tx.uplink != nil { modeGuide }
            if tx.mode == .aprsPosition { positionControls }
            if tx.mode?.usesMessage == true {
                row("Message") {
                    HStack(spacing: 4) {
                        TextField(messagePrompt, text: $tx.message)
                            .textFieldStyle(.roundedBorder).controlSize(.small).disabled(tx.isPressing)
                        if tx.mode?.slotSeconds != nil {
                            Button("CQ") { tx.message = tx.ftxCallingMessage }
                                .controlSize(.small).disabled(tx.isPressing)
                                .help("Fill in the standard calling message")
                        }
                    }
                }
            }
            row("Audio to") {
                Picker("", selection: $tx.audioDevice) {
                    Text(tx.mode?.isVoice == true ? "Radio's own microphone" : "Choose an output").tag(AudioOutput?.none)
                    ForEach(tx.outputs) { o in Text(o.name).tag(Optional(o)) }
                }
                .labelsHidden().controlSize(.small).disabled(tx.isPressing)
            }
        }
    }

    /// Which modes this uplink takes, which the app chose from automatically.
    private var modeGuide: some View {
        DisclosureGroup("All modes") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(TxMode.allCases) { m in
                    let here = tx.uplink?.modes.contains(m) == true
                    HStack(spacing: 5) {
                        Image(systemName: here ? "checkmark.circle.fill" : "circle").font(.system(size: 9))
                            .foregroundStyle(here ? Color.green : Color.secondary)
                        Text(m.rawValue).foregroundStyle(here ? Color.primary : Color.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("Winlink: no satellite gateway is listed").foregroundStyle(.secondary)
                }
                Text("A tick means this uplink takes it. Each satellite's listing decides, so there's nothing to set up.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10)).padding(.top, 2)
        }
        .font(.system(size: 11))
    }

    /// Exactly what will go out, since it's public and stays online once a ground station passes it on.
    private var positionControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("From") {
                if let s = app.station, !s.fromSpyHost {
                    Text(s.name).lineLimit(1)
                } else {
                    Text("Set your own location in the address bar").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row("Precision") {
                Picker("", selection: $tx.positionPrecision) {
                    ForEach(APRSPosition.Precision.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().controlSize(.small).disabled(tx.isPressing)
            }
            row("Comment") {
                TextField("Optional", text: $tx.positionComment)
                    .textFieldStyle(.roundedBorder).controlSize(.small).disabled(tx.isPressing)
            }
            if let report = tx.positionReport {
                row("Sends") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(tx.callsign.isEmpty ? "YOURCALL" : tx.callsign)>APZODK,\(tx.packetPath.joined(separator: ",")):\(report)")
                            .font(.system(size: 10, design: .monospaced)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text("Public once a ground station hears it, and may appear on sites like aprs.fi.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var messagePrompt: String {
        switch tx.mode {
        case .ft8, .ft4: tx.ftxCallingMessage
        case .aprs: "Status text"
        case .packet1200, .packet9600: "Packet text"
        default: "CQ CQ DE \(tx.callsign)"
        }
    }

    private func detailLine(_ u: Uplink) -> String {
        var parts: [String] = []
        if let d = tx.dopplerHz { parts.append(String(format: "Doppler %+.1f kHz", d / 1000)) }
        if let t = u.ctcssHz { parts.append(String(format: "tone %.1f Hz", t)) }
        if u.inverted { parts.append("inverting") }
        return parts.isEmpty ? u.modeName : parts.joined(separator: " · ")
    }

    private func mhz(_ hz: Double) -> String { String(format: "%.5f MHz", hz / 1e6) }

    private func row<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Station

    private var station: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Callsign") {
                TextField("Your callsign", text: Binding(
                    get: { tx.callsign },
                    set: { tx.callsign = $0.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }
                ))
                .textFieldStyle(.roundedBorder).controlSize(.small).disabled(tx.isPressing)
            }
            Toggle(isOn: $tx.licenceConfirmed) {
                Text("I hold an amateur licence covering this band and power")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.small).disabled(tx.isPressing)
            DisclosureGroup("Limits") {
                VStack(alignment: .leading, spacing: 4) {
                    row("Min elev.") {
                        Stepper("\(Int(tx.minElevation))°", value: $tx.minElevation, in: 5...45, step: 5).controlSize(.small)
                    }
                    row("Timeout") {
                        Stepper("\(Int(tx.timeoutSeconds)) s", value: $tx.timeoutSeconds, in: 20...300, step: 10).controlSize(.small)
                    }
                }
                .padding(.top, 3)
            }
            .disabled(tx.isPressing)
        }
    }

    private var radio: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Radio") {
                Picker("", selection: $tx.radioKind) {
                    ForEach(RadioKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().controlSize(.small).disabled(tx.isPressing)
            }
            radioSearch
            if tx.radioKind == .hamlib {
                row("Port") {
                    TextField("4532", value: $tx.rigPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 70)
                        .disabled(tx.isRadioConnected)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(radioColor)
                Text(radioText).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(tx.isRadioConnected ? "Disconnect" : "Connect") {
                    tx.isRadioConnected ? tx.disconnect() : tx.connect()
                }
                .controlSize(.small).disabled(tx.radio == .connecting || tx.isPressing)
            }
        }
    }

    /// What's been found on USB, which updates by itself when a radio is plugged in.
    private var radioSearch: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tx.foundRadio == nil ? "cable.connector.slash" : "cable.connector").font(.system(size: 10))
                .foregroundStyle(tx.foundRadio == nil ? Color.secondary : Color.green)
            Text(tx.radioSearchText).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button("Check again") { tx.searchForRadios(force: true) }
                .controlSize(.mini).disabled(tx.isRadioConnected || tx.isSearchingForRadio)
        }
        .task {
            while !Task.isCancelled {
                tx.searchForRadios()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var radioColor: Color {
        switch tx.radio {
        case .connected: .green
        case .failed: .red
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }

    private var radioText: String {
        switch tx.radio {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected:
            if tx.radioKind == .detected, let r = tx.foundRadio { "Connected to \(r.name): this transmits for real" }
            else { "Connected: this transmits for real" }
        case .failed(let m): m
        }
    }

    // MARK: Checks and button

    private var checklist: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tx.checks) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: c.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(c.pass ? Color.green : Color.red)
                            .font(.system(size: 10))
                        Text(c.id).frame(width: 70, alignment: .leading)
                        Text(c.detail).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 3)
        } label: {
            let open = tx.checks.filter { !$0.pass }.count
            Text(open == 0 ? "All checks pass" : "\(open) check\(open == 1 ? "" : "s") to clear")
        }
    }

    private var holdButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(tx.isKeyed ? Color.red : (tx.canTransmit ? Color.red.opacity(0.28) : Color.secondary.opacity(0.14)))
            HStack(spacing: 6) {
                Image(systemName: tx.isKeyed ? "dot.radiowaves.left.and.right" : "hand.point.up.left.fill")
                Text(buttonText).fontWeight(.semibold)
            }
            .font(.system(size: 12))
            .foregroundStyle(tx.canTransmit || tx.isKeyed ? Color.white : Color.secondary)
            HoldArea(onPress: { tx.press() }, onRelease: { tx.release() })
        }
        .frame(height: 38)
        .help("Transmits only while held")
    }

    private var buttonText: String {
        if tx.isKeyed { return "On air" }
        if tx.waitingForSlot { return "Hold: waiting for the UTC slot…" }
        if tx.isPressing { return "Tuning…" }
        return "Hold to transmit"
    }

    @ViewBuilder private var status: some View {
        if let a = tx.alarm {
            Label(a, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let at = tx.keyedAt, tx.isKeyed {
            HStack(spacing: 3) {
                Text("Keyed for")
                Text(at, style: .timer).monospacedDigit()
                Text("of \(Int(tx.timeoutSeconds)) s")
            }
            .foregroundStyle(.secondary)
        } else if let e = tx.lastEvent {
            Text(e).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Uplinks a satellite lists but that can't be used, greyed out, each with a button saying why.
struct RefusedUplinkList: View {
    let satellite: Satellite

    var body: some View {
        let refused = UplinkPolicy.refused(for: satellite)
        if !refused.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not available").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(refused.enumerated()), id: \.offset) { _, item in
                    RefusedUplinkRow(transmitter: item.transmitter, reasons: item.reasons)
                }
            }
            .padding(.top, 2)
        }
    }
}

struct RefusedUplinkRow: View {
    let transmitter: Transmitter
    let reasons: [Eligibility]
    @State private var showing = false

    private func mhz(_ hz: Double) -> String { String(format: "%.3f MHz", hz / 1e6) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(transmitter.description).font(.system(size: 11)).lineLimit(1)
                Text("Up \(transmitter.uplinkLowHz.map(mhz) ?? "-") \(transmitter.uplinkMode ?? transmitter.mode), down \(mhz(transmitter.downlinkHz))")
                    .font(.system(size: 10)).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .opacity(0.6)
            Spacer(minLength: 4)
            Button { showing.toggle() } label: {
                ZStack {
                    Circle().fill(Color(white: 0.72))
                    Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                }
                .frame(width: 15, height: 15)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Why it isn't available")
            .accessibilityLabel("Why \(transmitter.description) isn't available")
            .popover(isPresented: $showing, arrowEdge: .trailing) { RefusedReasons(transmitter: transmitter, reasons: reasons) }
        }
    }
}

struct RefusedReasons: View {
    let transmitter: Transmitter
    let reasons: [Eligibility]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why \(transmitter.description) isn't available").font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(reasons, id: \.self) { r in
                VStack(alignment: .leading, spacing: 1) {
                    Label(r.reason, systemImage: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                    Text(r.explanation).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            Text("From the SatNOGS database. If this changes there, it changes here within a day.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 270)
    }
}
