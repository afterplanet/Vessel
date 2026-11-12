import SwiftUI

/// Where the antenna is pointing against where the satellite is, on a compass and an elevation arc.
struct RotatorDial: View {
    @ObservedObject var rotator: RotatorController
    var compact = false

    private func compass(_ size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            ForEach(0..<36, id: \.self) { i in
                Rectangle().fill(Color.secondary.opacity(i % 9 == 0 ? 0.8 : 0.3))
                    .frame(width: 1, height: i % 9 == 0 ? 7 : 3)
                    .offset(y: -size / 2 + (i % 9 == 0 ? 3.5 : 1.5))
                    .rotationEffect(.degrees(Double(i) * 10))
            }
            ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { i, label in
                Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    .offset(y: -size / 2 + 15)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            if let az = rotator.targetAz {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    .offset(y: -size / 2 + 3)
                    .rotationEffect(.degrees(az))
                    .opacity((rotator.targetEl ?? -1) >= 0 ? 1 : 0.35)
            }
            if let az = rotator.actualAz {
                Capsule().fill(Color.primary).frame(width: 2, height: size / 2 - 8)
                    .offset(y: -(size / 2 - 8) / 2)
                    .rotationEffect(.degrees(az))
                    .animation(.linear(duration: 0.9), value: az)
            }
            Circle().fill(Color.primary).frame(width: 5, height: 5)
        }
        .frame(width: size, height: size)
    }

    private func elevation(_ size: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Path { p in
                p.addArc(center: CGPoint(x: 0, y: size), radius: size - 1, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            }
            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: 0, y: size)); p.addLine(to: CGPoint(x: size, y: size))
                p.move(to: CGPoint(x: 0, y: size)); p.addLine(to: CGPoint(x: 0, y: 0))
            }
            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            if let el = rotator.targetEl, el >= 0 {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    .position(x: (size - 2) * cos(el * .pi / 180), y: size - (size - 2) * sin(el * .pi / 180))
            }
            if let el = rotator.actualEl {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size))
                    p.addLine(to: CGPoint(x: (size - 6) * cos(el * .pi / 180), y: size - (size - 6) * sin(el * .pi / 180)))
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .animation(.linear(duration: 0.9), value: el)
            }
        }
        .frame(width: size, height: size)
    }

    private func value(_ title: String, actual: Double?, target: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(actual.map { String(format: "%.1f°", $0) } ?? "–").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            if let target {
                Text(String(format: "Satellite %.1f°", target)).font(.system(size: 9)).foregroundStyle(Color.accentColor).monospacedDigit().lineLimit(1)
            }
        }
    }

    private var activityText: String {
        switch rotator.activity {
        case .idle: "Not tracking"
        case .tracking: "Following the satellite"
        case .waitingAtRise: "Waiting where the satellite will rise"
        case .waitingForSatellite: rotator.targetAz == nil ? "Lock a satellite to follow it" : "Satellite is below the horizon"
        case .needsLocation: "Set your own location in the address bar"
        case .parked: "Moving to the park position"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: compact ? 8 : 12) {
                compass(compact ? 78 : 92)
                elevation(compact ? 46 : 58)
                VStack(alignment: .leading, spacing: 6) {
                    value("Azimuth", actual: rotator.actualAz, target: rotator.targetAz)
                    value("Elevation", actual: rotator.actualEl, target: rotator.targetEl)
                }
                .frame(minWidth: 0, alignment: .leading)
            }
            HStack(spacing: 5) {
                Circle().fill(rotator.activity == .tracking ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(activityText).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// In Listener, in the same form as the Source row: a button for the settings, which takes the
/// rotator's name once there is one. Only for sources using your own antenna.
struct RotatorStrip: View {
    @ObservedObject var rotator: RotatorController
    @EnvironmentObject var app: AppState
    @AppStorage("rotator.showBox") private var showBox = true

    private var failed: Bool {
        if case .failed = rotator.status { return true }
        return false
    }

    /// With the box hidden, the angles still show on the button.
    private var angles: String? {
        guard rotator.isConnected, !showBox, let az = rotator.actualAz, let el = rotator.actualEl else { return nil }
        return String(format: "%.0f° / %.0f°", az, el)
    }

    var body: some View {
        if app.supportsRotator {
            HStack {
                Text("Rotator").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                Button { rotator.showSettings.toggle() } label: {
                    HStack(spacing: 6) {
                        DishIcon(size: 12)
                            .foregroundStyle(rotator.isConnected ? (rotator.isTracking ? Color.green : Color.accentColor) : Color.secondary)
                        Text(rotator.isConnected ? rotator.displayName : "Set up").font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 2)
                        if let angles { Text(angles).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
                        if failed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        // Room for the eye, which sits over this end of the button.
                        if rotator.isConnected { Color.clear.frame(width: 18, height: 1) }
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(SelectorButtonStyle())
                .help(rotator.isConnected ? "Rotator settings" : "Set up an antenna rotator")
                .popover(isPresented: $rotator.showSettings, arrowEdge: .trailing) { RotatorSettings(rotator: rotator) }
                .overlay(alignment: .trailing) {
                    if rotator.isConnected {
                        Button { showBox.toggle() } label: {
                            Image(systemName: showBox ? "eye.slash" : "eye").font(.system(size: 10)).frame(width: 18, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 20)
                        .help(showBox ? "Hide the tracking box" : "Show the tracking box")
                        .accessibilityLabel(showBox ? "Hide the tracking box" : "Show the tracking box")
                    }
                }
            }
        }
    }
}

/// Tracking, live, just above the signal meter. The eye on the rotator's button in Listener hides it.
struct RotatorBox: View {
    @ObservedObject var rotator: RotatorController
    @EnvironmentObject var app: AppState
    @AppStorage("rotator.showBox") private var showBox = true

    var body: some View {
        if rotator.isConnected, app.supportsRotator, showBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("Tracking").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(app.locked?.name ?? "No satellite locked").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(app.locked == nil ? Color.secondary : Color.primary)
                }
                RotatorDial(rotator: rotator, compact: true)
                HStack(spacing: 6) {
                    Toggle("Follow satellite", isOn: Binding(get: { rotator.isTracking }, set: { rotator.setTracking($0) }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    Spacer(minLength: 2)
                    Button(role: .destructive) { rotator.stop() } label: { Text("Stop").font(.system(size: 10)) }
                        .controlSize(.mini).help("Stop the motors now")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }
}

/// A satellite dish on its mount, facing up and to the right.
struct DishIcon: View {
    var size: CGFloat = 13

    var body: some View {
        Canvas { context, canvas in
            let w = canvas.width, h = canvas.height
            let stroke = StrokeStyle(lineWidth: max(1, w * 0.1), lineCap: .round, lineJoin: .round)
            // The bowl, open towards the top right.
            var bowl = Path()
            bowl.move(to: CGPoint(x: w * 0.12, y: h * 0.30))
            bowl.addQuadCurve(to: CGPoint(x: w * 0.72, y: h * 0.86), control: CGPoint(x: w * 0.12, y: h * 0.90))
            bowl.closeSubpath()
            context.fill(bowl, with: .foreground)
            // The arm out to the receiver at its focus.
            var feed = Path()
            feed.move(to: CGPoint(x: w * 0.42, y: h * 0.58))
            feed.addLine(to: CGPoint(x: w * 0.72, y: h * 0.28))
            context.stroke(feed, with: .foreground, style: stroke)
            context.fill(Path(ellipseIn: CGRect(x: w * 0.66, y: h * 0.14, width: w * 0.2, height: w * 0.2)), with: .foreground)
            // The mount.
            var mount = Path()
            mount.move(to: CGPoint(x: w * 0.34, y: h * 0.74))
            mount.addLine(to: CGPoint(x: w * 0.22, y: h * 0.98))
            mount.move(to: CGPoint(x: w * 0.04, y: h * 0.98))
            mount.addLine(to: CGPoint(x: w * 0.50, y: h * 0.98))
            context.stroke(mount, with: .foreground, style: stroke)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Behind the rotator button in Listener.
struct RotatorSettings: View {
    @ObservedObject var rotator: RotatorController

    private func row<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusColor: Color {
        switch rotator.status {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .off: .secondary
        }
    }

    private var statusText: String {
        switch rotator.status {
        case .off: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected: this moves a real antenna"
        case .failed(let m): m
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Antenna rotator").font(.system(size: 13, weight: .semibold))
            row("Rotator") {
                Picker("", selection: $rotator.connection) {
                    ForEach(RotatorController.Connection.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().controlSize(.small)
            }
            .disabled(rotator.isConnected)
            if rotator.connection == .network {
                row("Address") {
                    HStack(spacing: 4) {
                        TextField("127.0.0.1", text: $rotator.address).textFieldStyle(.roundedBorder).controlSize(.small)
                        TextField("4533", value: $rotator.port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 56)
                    }
                }
                .disabled(rotator.isConnected)
            }
            if rotator.connection == .usb {
                Group {
                    row("Model") {
                        Picker("", selection: $rotator.usbModel) {
                            ForEach(rotator.usbModels, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().controlSize(.small)
                    }
                    row("Port") {
                        Picker("", selection: $rotator.usbPort) {
                            if rotator.usbPorts.isEmpty { Text("Nothing plugged in").tag("") }
                            ForEach(rotator.usbPorts, id: \.self) { Text($0.replacingOccurrences(of: "/dev/cu.", with: "")).tag($0) }
                        }
                        .labelsHidden().controlSize(.small)
                    }
                    row("Speed") {
                        Picker("", selection: $rotator.usbBaud) {
                            ForEach([1200, 4800, 9600, 19200, 38400, 57600, 115200], id: \.self) { Text("\($0) baud").tag($0) }
                        }
                        .labelsHidden().controlSize(.small)
                    }
                }
                .disabled(rotator.isConnected)
                .onAppear { rotator.loadUSBChoices() }
            }
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(statusColor)
                Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Button(rotator.isConnected ? "Disconnect" : "Connect") {
                    rotator.isConnected ? rotator.disconnect() : rotator.connect()
                }
                .controlSize(.small).disabled(rotator.status == .connecting)
            }

            if rotator.isConnected {
                Divider()
                RotatorDial(rotator: rotator)
                HStack(spacing: 6) {
                    Toggle("Follow satellite", isOn: Binding(get: { rotator.isTracking }, set: { rotator.setTracking($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Spacer(minLength: 2)
                    Button("Park") { rotator.park() }.controlSize(.small).help("Move to the park position below, and stop following")
                    Button(role: .destructive) { rotator.stop() } label: { Text("Stop") }
                        .controlSize(.small).help("Stop the motors now")
                }
            }

            DisclosureGroup("Settings") {
                VStack(alignment: .leading, spacing: 6) {
                    row("Update every") {
                        Stepper("\(Int(rotator.updateSeconds)) s", value: $rotator.updateSeconds, in: 1...30).controlSize(.small)
                    }
                    row("Lowest elev.") {
                        Stepper("\(Int(rotator.minElevation))°", value: $rotator.minElevation, in: 0...45, step: 5).controlSize(.small)
                    }
                    row("Ignore under") {
                        Stepper("\(Int(rotator.deadband))°", value: $rotator.deadband, in: 1...15).controlSize(.small)
                    }
                    row("Park at") {
                        HStack(spacing: 4) {
                            TextField("Az", value: $rotator.parkAz, format: .number).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 50)
                            Text("az")
                            TextField("El", value: $rotator.parkEl, format: .number).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 50)
                            Text("el")
                        }
                    }
                    Toggle("Rotator can turn past 360°, up to 450°", isOn: $rotator.turnsPast360).controlSize(.small)
                    Toggle("Rotator can tilt past 90°, up to 180°", isOn: $rotator.tiltsPast90).controlSize(.small)
                    if let path = rotator.path {
                        Text(path.downtime < 1 ? "Next pass is planned with no gaps in tracking."
                             : "Next pass is planned. The antenna will be off target for about \(Int(path.downtime.rounded())) s.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Wait where the satellite will rise", isOn: $rotator.waitAtRise).controlSize(.small)
                }
                .padding(.top, 4)
            }
            Text("Uses your own location from the address bar, even when listening through a public host.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .padding(14)
        .frame(width: 330)
    }
}
