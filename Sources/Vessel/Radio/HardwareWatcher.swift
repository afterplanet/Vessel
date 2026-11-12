import Foundation
import IOKit

/// How to recognise each receiver on USB, by the vendor and product numbers it reports. These come from the
/// USB rules and device tables in each driver's own source, so a dongle is known whatever it calls itself.
struct HardwareSignature: Equatable {
    let vendor: UInt16
    /// Nil for a vendor whose every device is this receiver.
    let product: UInt16?
    let sourceID: String
    let name: String

    init(_ vendor: UInt16, _ product: UInt16?, _ sourceID: String, _ name: String) {
        self.vendor = vendor
        self.product = product
        self.sourceID = sourceID
        self.name = name
    }

    /// Exact matches are tried before whole vendors.
    static func match(vendor: UInt16, product: UInt16) -> HardwareSignature? {
        all.first { $0.vendor == vendor && $0.product == product } ?? all.first { $0.vendor == vendor && $0.product == nil }
    }

    /// In the list, but with no USB numbers published anywhere that could be checked.
    /// These still show up through the engine's own device list, only a little more slowly.
    static let foundByEngineOnly: Set<String> = ["aaronia"]

    static let all: [HardwareSignature] = [
        // osmocom/rtl-sdr, src/librtlsdr.c: every dongle it knows.
        .init(0x0bda, 0x2832, "rtlsdr", "Generic RTL2832U"),
        .init(0x0bda, 0x2838, "rtlsdr", "Generic RTL2832U OEM"),
        .init(0x0413, 0x6680, "rtlsdr", "DigitalNow Quad DVB-T PCI-E card"),
        .init(0x0413, 0x6f0f, "rtlsdr", "Leadtek WinFast DTV Dongle mini D"),
        .init(0x0458, 0x707f, "rtlsdr", "Genius TVGo DVB-T03 USB dongle (Ver. B)"),
        .init(0x0ccd, 0x00a9, "rtlsdr", "Terratec Cinergy T Stick Black (rev 1)"),
        .init(0x0ccd, 0x00b3, "rtlsdr", "Terratec NOXON DAB/DAB+ USB dongle (rev 1)"),
        .init(0x0ccd, 0x00b4, "rtlsdr", "Terratec Deutschlandradio DAB Stick"),
        .init(0x0ccd, 0x00b5, "rtlsdr", "Terratec NOXON DAB Stick - Radio Energy"),
        .init(0x0ccd, 0x00b7, "rtlsdr", "Terratec Media Broadcast DAB Stick"),
        .init(0x0ccd, 0x00b8, "rtlsdr", "Terratec BR DAB Stick"),
        .init(0x0ccd, 0x00b9, "rtlsdr", "Terratec WDR DAB Stick"),
        .init(0x0ccd, 0x00c0, "rtlsdr", "Terratec MuellerVerlag DAB Stick"),
        .init(0x0ccd, 0x00c6, "rtlsdr", "Terratec Fraunhofer DAB Stick"),
        .init(0x0ccd, 0x00d3, "rtlsdr", "Terratec Cinergy T Stick RC (Rev.3)"),
        .init(0x0ccd, 0x00d7, "rtlsdr", "Terratec T Stick PLUS"),
        .init(0x0ccd, 0x00e0, "rtlsdr", "Terratec NOXON DAB/DAB+ USB dongle (rev 2)"),
        .init(0x1554, 0x5020, "rtlsdr", "PixelView PV-DT235U(RN)"),
        .init(0x15f4, 0x0131, "rtlsdr", "Astrometa DVB-T/DVB-T2"),
        .init(0x15f4, 0x0133, "rtlsdr", "HanfTek DAB+FM+DVB-T"),
        .init(0x185b, 0x0620, "rtlsdr", "Compro Videomate U620F"),
        .init(0x185b, 0x0650, "rtlsdr", "Compro Videomate U650F"),
        .init(0x185b, 0x0680, "rtlsdr", "Compro Videomate U680F"),
        .init(0x1b80, 0xd393, "rtlsdr", "GIGABYTE GT-U7300"),
        .init(0x1b80, 0xd394, "rtlsdr", "DIKOM USB-DVBT HD"),
        .init(0x1b80, 0xd395, "rtlsdr", "Peak 102569AGPK"),
        .init(0x1b80, 0xd397, "rtlsdr", "KWorld KW-UB450-T USB DVB-T Pico TV"),
        .init(0x1b80, 0xd398, "rtlsdr", "Zaapa ZT-MINDVBZP"),
        .init(0x1b80, 0xd39d, "rtlsdr", "SVEON STV20 DVB-T USB & FM"),
        .init(0x1b80, 0xd3a4, "rtlsdr", "Twintech UT-40"),
        .init(0x1b80, 0xd3a8, "rtlsdr", "ASUS U3100MINI_PLUS_V2"),
        .init(0x1b80, 0xd3af, "rtlsdr", "SVEON STV27 DVB-T USB & FM"),
        .init(0x1b80, 0xd3b0, "rtlsdr", "SVEON STV21 DVB-T USB & FM"),
        .init(0x1d19, 0x1101, "rtlsdr", "Dexatek DK DVB-T Dongle (Logilink VG0002A)"),
        .init(0x1d19, 0x1102, "rtlsdr", "Dexatek DK DVB-T Dongle (MSI DigiVox mini II V3.0)"),
        .init(0x1d19, 0x1103, "rtlsdr", "Dexatek Technology Ltd. DK 5217 DVB-T Dongle"),
        .init(0x1d19, 0x1104, "rtlsdr", "MSI DigiVox Micro HD"),
        .init(0x1f4d, 0xa803, "rtlsdr", "Sweex DVB-T USB"),
        .init(0x1f4d, 0xb803, "rtlsdr", "GTek T803"),
        .init(0x1f4d, 0xc803, "rtlsdr", "Lifeview LV5TDeluxe"),
        .init(0x1f4d, 0xd286, "rtlsdr", "MyGica TD312"),
        .init(0x1f4d, 0xd803, "rtlsdr", "PROlectrix DV107669"),
        // airspy/airspyone_host, 52-airspy.rules. HydraSDR's old boards share this, which the engine then tells apart.
        .init(0x1d50, 0x60a1, "airspy", "Airspy"),
        // airspy/airspyhf, 52-airspyhf.rules.
        .init(0x03eb, 0x800c, "airspyhf", "Airspy HF+"),
        // hydrasdr/rfone_host, 51-hydrasdr.rules.
        .init(0x38af, 0x0001, "hydrasdr", "HydraSDR RFOne"),
        // greatscottgadgets/hackrf, 53-hackrf.rules.
        .init(0x1d50, 0x6089, "hackrf", "HackRF One"),
        .init(0x1d50, 0x604b, "hackrf", "HackRF Jawbreaker"),
        .init(0x1d50, 0xcc15, "hackrf", "rad1o"),
        // Mirics make the chips in every SDRplay, so this vendor covers the models past the ones in libmirisdr's rules.
        .init(0x1df7, nil, "sdrplay", "SDRplay RSP"),
        // f4exb/libmirisdr-4, mirisdr.rules. Its 1df7 entries are SDRplay's, above.
        .init(0x04bb, 0x0537, "mirisdr", "Mirics dongle"),
        // myriadrf/LimeSuite, 64-limesuite.rules. It also lists Cypress's generic 04b4 numbers, which plenty
        // of other things use, so a board reporting those is left to the engine to name.
        .init(0x1d50, 0x6108, "limesdr", "LimeSDR USB"),
        .init(0x0403, 0x601f, "limesdr", "LimeSDR Mini"),
        // Nuand/bladeRF, 88-nuand-bladerf1 and 2 rules.
        .init(0x2cf0, 0x5246, "bladerf", "bladeRF"),
        .init(0x1d50, 0x6066, "bladerf", "bladeRF"),
        .init(0x2cf0, 0x5250, "bladerf", "bladeRF 2.0"),
        // EttusResearch/uhd, uhd-usrp.rules.
        .init(0xfffe, 0x0002, "usrp", "USRP"),
        .init(0x2500, 0x0002, "usrp", "USRP"),
        .init(0x2500, 0x0020, "usrp", "USRP B200/B210"),
        .init(0x2500, 0x0021, "usrp", "USRP B200 mini"),
        .init(0x2500, 0x0022, "usrp", "USRP B205 mini"),
        .init(0x2500, 0x0023, "usrp", "USRP B200 mini"),
        .init(0x3923, 0x7813, "usrp", "NI USRP-2900"),
        .init(0x3923, 0x7814, "usrp", "NI USRP-2901"),
        // rigexpert/libfobos, 73-fobos-sdr.rules.
        .init(0x16d0, 0x132e, "fobos", "Fobos SDR"),
        // rfnm/librfnm, constants.h.
        .init(0x15a2, 0x008c, "rfnm", "RFNM"),
        .init(0x15a2, 0x008d, "rfnm", "RFNM"),
        // analogdevicesinc/plutosdr-fw, 53-adi-plutosdr-usb.rules. Over USB it's reached at a network address.
        .init(0x0456, 0xb673, "plutosdr", "PlutoSDR"),
        .init(0x2fa2, 0x5a02, "plutosdr", "PlutoSDR"),
    ]
}

/// A receiver that's actually plugged in.
struct AttachedHardware: Equatable, Identifiable {
    let sourceID: String
    var name: String
    var count = 1
    var id: String { sourceID }

    /// The source's name and the device's own, unless they'd say the same thing twice.
    var title: String {
        let base = SDRCatalog.source(sourceID)?.name ?? sourceID
        let shown = name.isEmpty || name == base ? base : "\(base) (\(name))"
        return count > 1 ? "\(shown) × \(count)" : shown
    }

    /// One entry per source from what USB shows, with anything only the engine knows about added.
    static func from(usb: [(vendor: UInt16, product: UInt16, name: String?)]) -> [AttachedHardware] {
        var out: [AttachedHardware] = []
        for device in usb {
            guard let signature = HardwareSignature.match(vendor: device.vendor, product: device.product) else { continue }
            if let i = out.firstIndex(where: { $0.sourceID == signature.sourceID }) {
                out[i].count += 1
            } else {
                let own = device.name?.trimmingCharacters(in: .whitespaces) ?? ""
                out.append(AttachedHardware(sourceID: signature.sourceID, name: own.isEmpty ? signature.name : own))
            }
        }
        return out
    }

    /// Which source to change to, if any. Only ever for a change in what's plugged in, so a choice
    /// made in the menu stays. Several devices are left for you to choose between.
    static func sourceToUse(current: String, old: [AttachedHardware], new: [AttachedHardware], firstLook: Bool) -> String? {
        let arrived = new.contains { device in !old.contains { $0.sourceID == device.sourceID } }
        if new.count == 1, firstLook || arrived { return new[0].sourceID }
        // What was in use has been pulled out.
        if old.contains(where: { $0.sourceID == current }), !new.contains(where: { $0.sourceID == current }) {
            return new.count == 1 ? new[0].sourceID : SDRCatalog.sources[0].id
        }
        return nil
    }

    static func merge(usb: [AttachedHardware], probed: [DetectedDevice]) -> [AttachedHardware] {
        var out = usb
        let hardwareTypes = probed.filter { p in
            guard let s = SDRCatalog.source(p.type) else { return false }
            return s.kind == .usb
        }
        // An old HydraSDR reports Airspy's numbers, and the engine knows which it really is.
        if hardwareTypes.contains(where: { $0.type == "hydrasdr" }), !hardwareTypes.contains(where: { $0.type == "airspy" }) {
            out.removeAll { $0.sourceID == "airspy" }
        }
        for p in hardwareTypes {
            if let i = out.firstIndex(where: { $0.sourceID == p.type }) {
                out[i].name = p.name // Usually more specific, such as "Realtek RTL2838UHIDIR #00000001".
            } else {
                out.append(AttachedHardware(sourceID: p.type, name: p.name))
            }
        }
        return out
    }
}

/// Follows USB as things are plugged in and pulled out. Reading what's attached needs no driver and
/// touches no device, so it can't get in the way of a capture.
@MainActor
final class USBWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: Task<Void, Never>?
    var onChange: (([AttachedHardware]) -> Void)?

    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            USBWatcher.drain(iterator)
            guard let context else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(p, kind, IOServiceMatching("IOUSBHostDevice"), callback, me, &iterator) == KERN_SUCCESS {
                iterators.append(iterator)
                // Notifications only begin once the existing ones are read.
                Self.drain(iterator)
            }
        }
    }

    nonisolated private static func drain(_ iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != 0 { IOObjectRelease(device) }
    }

    /// A burst of these comes with each device, which may still be listed for a moment after it's gone.
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.onChange?(Self.scan())
        }
    }

    static func scan() -> [AttachedHardware] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [(vendor: UInt16, product: UInt16, name: String?)] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            func value(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let vendor = (value("idVendor") as? NSNumber)?.uint16Value,
                  let product = (value("idProduct") as? NSNumber)?.uint16Value else { continue }
            devices.append((vendor, product, value("USB Product Name") as? String))
        }
        return AttachedHardware.from(usb: devices)
    }
}

/// RTL-SDR dongles all look alike on USB, but what they can tune depends on the chip inside, which only
/// shows when the device is opened. The driver announces it then: "Found Rafael Micro R820T tuner".
enum RTLTuner: String, Equatable {
    case r820t = "R820T", r828d = "R828D", blogV4 = "RTL-SDR Blog V4", e4000 = "E4000", fc0012 = "FC0012", fc0013 = "FC0013", fc2580 = "FC2580"

    private static func mhz(_ low: Double, _ high: Double) -> ClosedRange<Double> { (low * 1e6)...(high * 1e6) }

    var ranges: [ClosedRange<Double>] {
        switch self {
        case .r820t, .r828d: [Self.mhz(24, 1766)]
        // Its built-in upconverter adds shortwave below the tuner's own range.
        case .blogV4: [Self.mhz(0.5, 1766)]
        // A real gap in the chip's coverage.
        case .e4000: [Self.mhz(52, 1100), Self.mhz(1250, 2200)]
        case .fc0012: [Self.mhz(22, 948.6)]
        case .fc0013: [Self.mhz(22, 1100)]
        case .fc2580: [Self.mhz(146, 308), Self.mhz(438, 924)]
        }
    }

    /// From the driver's output. A Blog V4 announces itself as well as its R828D, in either order.
    static func parse(_ log: String) -> RTLTuner? {
        if log.contains("Blog V4") { return .blogV4 }
        if log.contains("R820T") { return .r820t }
        if log.contains("R828D") { return .r828d }
        if log.contains("E4000") { return .e4000 }
        if log.contains("FC0012") { return .fc0012 }
        if log.contains("FC0013") { return .fc0013 }
        if log.contains("FCI 2580") { return .fc2580 }
        return nil
    }
}

/// Opens the dongle just long enough to read which chip it has, using nothing but receiving.
@MainActor
final class RTLTunerProbe {
    private var process: Process?

    func identify(engine: URL, folder: URL, done: @escaping @MainActor (RTLTuner?) -> Void) {
        guard process == nil else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rtlprobe-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = engine
        p.arguments = ["legacy", "record", work.appendingPathComponent("x").path, "--baseband_format", "cs8", "--source", "rtlsdr",
                       "--samplerate", "1000000", "--frequency", "100000000", "--timeout", "1"]
        p.currentDirectoryURL = folder
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = TunerBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            buffer.add(h.availableData)
            // No need to wait for the recording once the chip's been named.
            if buffer.tuner != nil, p.isRunning { p.terminate() }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            buffer.add(pipe.fileHandleForReading.availableData)
            try? FileManager.default.removeItem(at: work)
            let found = buffer.tuner
            Task { @MainActor in
                self?.process = nil
                done(found)
            }
        }
        do {
            try p.run()
            process = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak p] in if let p, p.isRunning { p.terminate() } }
        } catch {
            done(nil)
        }
    }

    /// A capture needs the dongle more than this does.
    func cancel() { if let p = process, p.isRunning { p.terminate() } }
}

private final class TunerBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func add(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        text += String(decoding: data, as: UTF8.self)
        lock.unlock()
    }

    var tuner: RTLTuner? {
        lock.lock()
        defer { lock.unlock() }
        // Only the driver's own line: the name "R820T" can't appear in anything else here, but a Blog V4's follows.
        guard text.contains(" tuner") else { return nil }
        return text.contains("Found ") ? RTLTuner.parse(text.split(whereSeparator: \.isNewline).filter { $0.contains("Found ") || $0.contains("Blog V4") }.joined(separator: "\n")) : nil
    }
}
