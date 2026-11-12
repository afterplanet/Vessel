import SwiftUI
import AppKit
import simd

/// `VESSEL_TEST="--tx-test --rig-port N"` drives the real controller and button view against a
/// rigctld you started yourself, and prints what the radio reports at each step. It refuses any
/// port unless told it is simulated, so it can't key a real transmitter.
@MainActor
enum TxSelfTest {
    private static func log(_ s: String) { FileHandle.standardError.write(Data("txtest: \(s)\n".utf8)) }

    private static func views<T: NSView>(of type: T.Type, in v: NSView) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views(of: type, in: $0) }
    }

    static func runIfRequested(store: SatelliteStore, app: AppState, tx: TransmitController) {
        let a = Snapshot.arguments
        if let i = a.firstIndex(of: "--write-signals") { writeSignals(to: a[i + 1]) }
        guard a.contains("--tx-test"), a.contains("--i-started-a-dummy-rig"),
              let i = a.firstIndex(of: "--rig-port"), let port = Int(a[i + 1]) else { return }
        Task { await run(port: port, hold: a.contains("--tx-hold-for-kill"), store: store, app: app, tx: tx) }
    }

    /// Writes signals to WAV files for independent decoders, and opens the audio path at zero volume.
    private static func writeSignals(to dir: String) {
        let aprs = AudioSignals.aprs(source: "N0CALL-7", path: ["ARISS"], text: "Vessel test 123")
        let silence = [Float](repeating: 0, count: 24_000)
        try? AudioSignals.wav(silence + aprs + silence).write(to: URL(fileURLWithPath: dir + "/aprs.wav"))
        try? AudioSignals.wav(AudioSignals.cw(text: "CQ DE N0CALL K", wpm: 18)).write(to: URL(fileURLWithPath: dir + "/cw.wav"))
        func write(_ mode: TxMode, _ text: String, usb: Bool = true, _ name: String, slot: Double? = nil) {
            guard var s = TxSignal.render(mode: mode, message: text, callsign: "N0CALL-7", path: ["APRSAT"], usb: usb) else { log("FAIL render \(name)"); return }
            if let slot {
                // Where a real transmission sits in its slot, for the decoder.
                s = [Float](repeating: 0, count: 24_000) + s
                s += [Float](repeating: 0, count: max(0, Int(slot * AudioSignals.sampleRate) - s.count))
            } else {
                s = silence + s + silence
            }
            try? AudioSignals.wav(s).write(to: URL(fileURLWithPath: "\(dir)/\(name).wav"))
        }
        write(.packet1200, "Hello packet 1200", "packet1200")
        write(.packet9600, "Hello packet 9600", "packet9600")
        write(.rtty, "RYRYRY CQ TEST 123 DE N0CALL", "rtty_usb")
        write(.rtty, "RYRYRY CQ TEST 123 DE N0CALL", usb: false, "rtty_lsb")
        write(.psk31, "CQ de N0CALL test 123", "psk31")
        write(.ft8, "CQ N0CALL FN31", "ft8", slot: 15)
        write(.ft4, "CQ N0CALL FN31", "ft4", slot: 7.5)
        let router = AudioRouter()
        guard let out = AudioRouter.outputs().first else { log("no audio outputs"); return }
        log("audio outputs: \(AudioRouter.outputs().map(\.name))")
        do {
            try router.play(silence, device: out.id, volume: 0) { log("PASS audio path played to the end on \(out.name), silently"); _ = router }
        } catch { log("FAIL audio path: \(error.localizedDescription)") }
    }

    private static func under(_ sat: Satellite) -> Station {
        let jd = Astro.julianDate()
        let e = Astro.ecef(sat.state(jd: jd)!.r, gmst: Astro.gmst(jd))
        return Station(name: "Test point", lat: asin(e.z / simd_length(e)) * 180 / .pi, lon: atan2(e.y, e.x) * 180 / .pi, iso: "")
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private static func run(port: Int, hold: Bool, store: SatelliteStore, app: AppState, tx: TransmitController) async {
        let probe = RigLink(label: "probe")
        try? await probe.connect(port: port)
        func radio() async -> String {
            let t = (try? await probe.get("t")) ?? "?"
            let i = (try? await probe.get("i")) ?? "?"
            let f = (try? await probe.get("f")) ?? "?"
            return "ptt=\(t) tx=\(i) rx=\(f)"
        }
        func expect(_ name: String, _ ok: Bool, _ detail: String = "") { log("\(ok ? "PASS" : "FAIL") \(name) \(detail)") }

        guard let iss = store.satellite(norad: 25544), let starlink = store.satellites.first(where: { $0.name.hasPrefix("STARLINK") }) else {
            log("FAIL no satellites"); return
        }
        let saved = (tx.callsign, tx.licenceConfirmed, tx.timeoutSeconds, tx.minElevation, tx.rigPort, app.station, tx.radioKind)
        defer {
            tx.callsign = saved.0; tx.licenceConfirmed = saved.1; tx.timeoutSeconds = saved.2
            tx.minElevation = saved.3; tx.rigPort = saved.4; app.station = saved.5
        }
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let root = win.contentView else { log("FAIL no window"); return }
        app.panelMode = .transmit
        await wait(1)
        guard let button = views(of: HoldNSView.self, in: root).first else { log("FAIL no hold button in window"); return }
        let ev = { (t: NSEvent.EventType) in
            NSEvent.mouseEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var currentButton = button
        let down = { currentButton.mouseDown(with: ev(.leftMouseDown)) }
        let up = { currentButton.mouseUp(with: ev(.leftMouseUp)) }

        // 1. Out of the box, nothing can key.
        tx.callsign = ""; tx.licenceConfirmed = false
        app.lock(iss)
        await wait(0.5)
        down(); await wait(0.5); up()
        var r = await radio()
        expect("unconfigured press is blocked", !tx.isKeyed && r.hasPrefix("ptt=0"), tx.lastEvent ?? "")

        // 2. Configure for a pass overhead, connect to the dummy rig.
        tx.callsign = "N0CALL"; tx.licenceConfirmed = true; tx.timeoutSeconds = 300
        app.sourceID = "rtlsdr"
        app.station = under(iss)
        tx.rigPort = port
        tx.radioKind = .hamlib
        tx.connect()
        await wait(3)
        expect("radio connected and uplink confirmed", tx.uplinkConfirmed, await radio())
        log("uplink=\(tx.uplink?.description ?? "-") mode=\(tx.mode?.rawValue ?? "-") doppler=\(tx.dopplerHz ?? 0)")
        expect("all checks pass", tx.canTransmit, tx.checks.filter { !$0.pass }.map(\.id).joined(separator: ","))
        let tone = (try? await probe.get("c")) ?? "?"
        expect("ISS repeater tone sent", tone == "670", "c=\(tone)")
        let split = (try? await probe.get("s", lines: 2)) ?? "?"
        expect("split on", split == "1", "s=\(split)")

        // The tab can't be left with the radio keyed.
        NSApp.activate(ignoringOtherApps: true)
        await wait(1.5)
        down(); await wait(1)
        if !tx.isKeyed {
            // Something else took focus first, which rightly stops it. One more try.
            up()
            NSApp.activate(ignoringOtherApps: true)
            await wait(2)
            down(); await wait(1)
        }
        expect("keyed before switching tab", tx.isKeyed)
        app.panelMode = .receive
        await wait(0.8)
        r = await radio()
        expect("switching to Receive drops transmit", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        app.panelMode = .transmit
        await wait(0.8)
        guard let again = views(of: HoldNSView.self, in: root).first else { log("FAIL no hold button after switching back"); return }
        currentButton = again

        // 3. Hold keys it, release unkeys it.
        down(); await wait(1)
        r = await radio()
        expect("hold keys the radio", tx.isKeyed && r.hasPrefix("ptt=1"), r)
        up(); await wait(0.5)
        r = await radio()
        expect("release unkeys the radio", !tx.isKeyed && r.hasPrefix("ptt=0"), r)

        // 4. Doppler moves while tracking.
        let f1 = tx.txHz ?? 0; await wait(3); let f2 = tx.txHz ?? 0
        log("tx frequency over 3 s: \(Int(f1)) -> \(Int(f2)), nominal \(Int(tx.uplink?.lowHz ?? 0))")
        expect("tx within Doppler range of the listed uplink", abs(f2 - (tx.uplink?.lowHz ?? 0)) < 5_000)

        // 5. Each automatic stop.
        tx.timeoutSeconds = 2
        down(); await wait(3.2)
        r = await radio()
        expect("timeout drops transmit", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        up(); down(); await wait(0.6)
        tx.timeoutSeconds = 300
        up(); await wait(0.4)

        down(); await wait(0.8)
        expect("keyed before horizon test", tx.isKeyed)
        app.station = Station(name: "Antipode", lat: -(app.station?.lat ?? 0), lon: (app.station?.lon ?? 0) + 180, iso: "")
        await wait(0.8)
        r = await radio()
        expect("below minimum elevation drops transmit", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        up()
        down(); await wait(0.5); up()
        r = await radio()
        expect("can't key while below the limit", !tx.isKeyed && r.hasPrefix("ptt=0"), tx.lastEvent ?? "")
        app.station = under(iss)
        await wait(1.5)

        down(); await wait(0.8)
        app.sourceID = "spyserver"
        await wait(0.6)
        r = await radio()
        expect("switching to a network source drops transmit", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        up()
        app.sourceID = "rtlsdr"
        await wait(0.6)

        down(); await wait(0.8)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        await wait(0.5)
        r = await radio()
        expect("losing focus drops transmit", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        up()

        // 6. Satellites without a public uplink.
        app.lock(starlink)
        await wait(0.6)
        app.station = under(starlink)
        await wait(1.5)
        down(); await wait(0.6); up()
        r = await radio()
        expect("Starlink is receive only", tx.uplinks.isEmpty && !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        var refused = 0, total = 0
        for s in store.satellites where s.category == .military || s.category == .weather || s.category == .navigation {
            total += 1
            if UplinkPolicy.uplinks(for: s).isEmpty { refused += 1 }
        }
        expect("military, weather and navigation are all receive only", refused == total, "\(refused)/\(total)")
        let eligible = store.satellites.filter { !UplinkPolicy.uplinks(for: $0).isEmpty }
        log("catalogue: \(eligible.count) satellites transmittable, \(eligible.flatMap(UplinkPolicy.uplinks).count) uplinks: \(eligible.prefix(12).map(\.name).joined(separator: ", "))")

        // 7. Satellite change during a hold.
        app.lock(iss)
        app.station = under(iss)
        await wait(2)
        down(); await wait(0.8)
        app.lock(starlink)
        await wait(0.5)
        r = await radio()
        expect("changing satellite drops transmit", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        up()

        // 8. Generated messages, sent silently. A packet ends by itself; CW stops on release.
        tx.outputVolume = 0
        tx.audioDevice = AudioRouter.outputs().first
        app.lock(iss)
        app.station = under(iss)
        await wait(2)
        tx.uplink = tx.uplinks.first { $0.modes.contains(.aprs) }
        tx.mode = .aprs
        tx.message = "Vessel test"
        await wait(1.5)
        expect("APRS uplink is selectable", tx.mode == .aprs && tx.canTransmit, "\(tx.uplink?.description ?? "-") \(tx.checks.filter { !$0.pass }.map(\.id))")
        down(); await wait(0.6)
        r = await radio()
        expect("APRS keys while sending", tx.isKeyed && r.hasPrefix("ptt=1"), r)
        await wait(2.5)
        r = await radio()
        expect("APRS unkeys when the packet ends", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        up()

        if let cwSat = store.satellites.first(where: { s in UplinkPolicy.uplinks(for: s).contains { $0.modes.contains(.cw) } }) {
            app.lock(cwSat)
            await wait(0.3)
            app.station = under(cwSat)
            await wait(1.5)
            tx.uplink = tx.uplinks.first { $0.modes.contains(.cw) }
            tx.mode = .cw
            tx.passbandPosition = 1
            tx.message = "CQ CQ CQ DE N0CALL N0CALL N0CALL K"
            await wait(1.5)
            let u = tx.uplink
            let inBand = abs((tx.txHz ?? 0) - (u?.highHz ?? 0)) < 12_000
            expect("linear uplink tuned to the passband on \(cwSat.name)", inBand, "tx=\(Int(tx.txHz ?? 0)) band=\(Int(u?.lowHz ?? 0))-\(Int(u?.highHz ?? 0)) inverted=\(u?.inverted ?? false) rx=\(Int(tx.rxHz ?? 0))")
            down(); await wait(1)
            r = await radio()
            expect("CW keys while held", tx.isKeyed && r.hasPrefix("ptt=1"), r)
            up(); await wait(0.5)
            r = await radio()
            expect("releasing mid-message stops CW", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
        }
        // Each digital mode, end to end on a linear transponder and a 9600 digipeater.
        if let lin = store.satellites.first(where: { s in UplinkPolicy.uplinks(for: s).contains { $0.modes.contains(.ft8) } }) {
            app.lock(lin)
            await wait(0.3)
            app.station = under(lin)
            await wait(1.5)
            tx.uplink = tx.uplinks.first { $0.modes.contains(.ft8) }
            tx.passbandPosition = 1
            for (m, text, sends) in [(TxMode.psk31, "TEST", 8.0), (.rtty, "RY", 3.0)] {
                tx.mode = m
                tx.message = text
                await wait(1.2)
                down(); await wait(1)
                r = await radio()
                expect("\(m.rawValue) keys on \(lin.name)", tx.isKeyed && r.hasPrefix("ptt=1"), "signal=\(Int(tx.signalHz ?? 0)) \(r)")
                await wait(sends)
                r = await radio()
                expect("\(m.rawValue) unkeys when sent", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
                up()
                await wait(0.3)
            }
            tx.passbandPosition = 0.5
            for m in [TxMode.ft4, .ft8] {
                tx.mode = m
                tx.message = tx.ftxCallingMessage
                await wait(1.2)
                down()
                let slot = m.slotSeconds!
                var waited = 0.0
                while !tx.isKeyed, waited < slot + 2 { await wait(0.05); waited += 0.05 }
                let phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: slot)
                let offset = min(phase, slot - phase)
                r = await radio()
                expect("\(m.rawValue) keys on the UTC slot", tx.isKeyed && offset < 0.6 && r.hasPrefix("ptt=1"), String(format: "%.2fs from a slot, message %@ %@", offset, tx.message, r))
                await wait(m == .ft8 ? 13.5 : 5.3)
                r = await radio()
                expect("\(m.rawValue) unkeys when sent", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
                up()
                await wait(0.3)
            }
            // Releasing during the wait must not key later.
            tx.mode = .ft8
            await wait(0.5)
            let toSlot = 15 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 15)
            if toSlot < 3 { await wait(toSlot + 0.5) }
            down(); await wait(0.5); up()
            await wait(15)
            r = await radio()
            expect("releasing during the slot wait never keys", !tx.isKeyed && r.hasPrefix("ptt=0"), r)
        }
        if let fast = store.satellites.first(where: { s in UplinkPolicy.uplinks(for: s).contains { $0.modes.contains(.packet9600) } }) {
            app.lock(fast)
            await wait(0.3)
            app.station = under(fast)
            await wait(1.5)
            tx.uplink = tx.uplinks.first { $0.modes.contains(.packet9600) }
            tx.mode = .packet9600
            tx.message = "Vessel test"
            await wait(1.2)
            down(); await wait(0.25)
            r = await radio()
            expect("Packet 9600 keys on \(fast.name)", r.hasPrefix("ptt=1"), r)
            await wait(1.5)
            r = await radio()
            expect("Packet 9600 unkeys when sent", !tx.isKeyed && r.hasPrefix("ptt=0"), "\(tx.lastEvent ?? "") \(r)")
            up()
        } else {
            log("no 9600 digipeater in the catalogue today")
        }
        let modeCounts = Dictionary(grouping: eligible.flatMap(UplinkPolicy.uplinks).flatMap(\.modes), by: \.rawValue).mapValues(\.count)
        log("uplinks per mode: \(modeCounts.sorted { $0.key < $1.key })")

        tx.outputVolume = 1
        tx.audioDevice = nil
        tx.message = ""

        tx.disconnect()
        await wait(0.5)
        tx.radioKind = .hamlib
        tx.connect()
        await wait(2)

        // 10. Left keyed, for the script to test the crash guard with kill -9.
        if hold {
            app.lock(iss)
            app.station = under(iss)
            await wait(2)
            down(); await wait(1)
            log("KEYED pid=\(getpid()) \(await radio())")
            await wait(120)
        }
        log("DONE")
    }
}
