import SwiftUI

/// What a stretch of spectrum shows. Noise always has small peaks, so this works on a time
/// average, where they settle down and anything that's really there stands out.
struct SpectrumReading: Equatable {
    var floorDB: Float
    var peakExcessDB: Float
    var peakOffsetHz: Double
    var widthHz: Double
    var onFrequency: Bool
    var elsewhere: Bool
    /// All-zero samples: the receiver is connected but nothing is coming through it.
    var silent: Bool

    static let nothing = SpectrumReading(floorDB: 0, peakExcessDB: 0, peakOffsetHz: 0, widthHz: 0, onFrequency: false, elsewhere: false, silent: false)

    /// Thresholds set from captures of live hosts: noise peaks reached 1 to 2 dB over the floor,
    /// and weak real signals 3 to 4 dB across several bins.
    static let wideExcess: Float = 3
    static let narrowExcess: Float = 6

    static func analyse(frames: [[Float]], frequency: Double, sampleRate: Double) -> SpectrumReading? {
        guard let n = frames.first?.count, n > 40, sampleRate > 0 else { return nil }
        var avg = [Float](repeating: 0, count: n)
        var used = 0
        for f in frames where f.count == n {
            for i in 0..<n { avg[i] += f[i] }
            used += 1
        }
        guard used > 0 else { return nil }
        for i in 0..<n { avg[i] /= Float(used) }

        // The outer tenth on each side is filter roll-off, which isn't information.
        let edge = n / 10
        let mid = Array(avg[edge..<(n - edge)]).sorted()
        let floorDB = mid[mid.count / 2]
        if floorDB <= -150 {
            return SpectrumReading(floorDB: floorDB, peakExcessDB: 0, peakOffsetHz: 0, widthHz: 0, onFrequency: false, elsewhere: false, silent: true)
        }

        let binHz = sampleRate / Double(n)
        let centre = n / 2
        // Most receivers have a spike at their own centre, which says nothing about the sky.
        let dcGuard = max(2, n / 256)
        // Doppler at most, plus a typical signal's half-width. A wider signal still counts,
        // because some part of it reaches into this window.
        let window = frequency * 2.5e-5 + min(75_000, sampleRate * 0.1)

        var best = (excess: Float(0), bin: centre)
        var bestWidth = 0
        var onFrequency = false
        var elsewhere = false
        var run: [Int] = []
        var nearBest = false

        func closeRun() {
            guard !run.isEmpty else { return }
            let peak = run.max { avg[$0] < avg[$1] }!
            let excess = avg[peak] - floorDB
            if excess >= narrowExcess || (excess >= wideExcess && run.count >= 2) {
                let near = run.contains { abs(Double($0 - centre) * binHz) <= window }
                if near { onFrequency = true } else { elsewhere = true }
                // A signal on frequency is what's reported, even when something stronger is elsewhere.
                if (near && !nearBest) || (near == nearBest && excess > best.excess) {
                    best = (excess, peak)
                    bestWidth = run.count
                    nearBest = near
                }
            }
            run = []
        }
        for i in edge..<(n - edge) {
            if abs(i - centre) <= dcGuard { closeRun(); continue }
            if avg[i] - floorDB >= wideExcess { run.append(i) } else { closeRun() }
        }
        closeRun()

        return SpectrumReading(floorDB: floorDB, peakExcessDB: best.excess, peakOffsetHz: Double(best.bin - centre) * binHz,
                               widthHz: Double(bestWidth) * binHz, onFrequency: onFrequency, elsewhere: elsewhere, silent: false)
    }
}

enum HealthLevel: Int { case unknown, good, caution, bad
    var color: Color {
        switch self {
        case .unknown: .gray
        case .good: .green
        case .caution: .yellow
        case .bad: .red
        }
    }
}

struct HealthVerdict: Equatable {
    var level: HealthLevel
    var title: String
    var detail: String

    /// Seconds of unbroken noise before saying so firmly, because a pass can start weak.
    static let noiseGrace: TimeInterval = 20

    /// Bytes per sample for each raw format, for working out what should be arriving.
    /// Formats that compress have no fixed rate, so they aren't in here.
    static func bytesPerSample(_ format: String) -> Double? {
        ["cf32": 8, "cs32": 8, "cs16": 4, "wav16": 4, "cs8": 2, "cu8": 2][format]
    }

    static func judge(reading: SpectrumReading?, mode: CaptureMode, framesLocked: Bool, elevation: Double?, noiseSeconds: TimeInterval, arrival: Double? = nil) -> HealthVerdict {
        if framesLocked {
            return HealthVerdict(level: .good, title: "Real data", detail: "The decoder is locked and producing frames.")
        }
        guard let r = reading else {
            return HealthVerdict(level: .unknown, title: "Analysing", detail: "Waiting for enough signal to judge.")
        }
        if r.silent {
            return HealthVerdict(level: .bad, title: "Receiver sending nothing", detail: "The samples are empty, so this host isn't delivering any signal. Try another.")
        }
        // Gaps wreck a recording however strong the signal looks, so this comes before the signal.
        if let arrival, arrival < 0.7 {
            let percent = max(1, Int((arrival * 100).rounded()))
            return HealthVerdict(level: arrival < 0.25 ? .bad : .caution, title: "Losing samples",
                                 detail: "Only \(percent)% of the signal is arriving, so this recording will have gaps. The host or its connection can't keep up. Try another host, or a lower sample rate.")
        }
        let strength = String(format: "+%.1f dB", r.peakExcessDB)
        if r.onFrequency, let e = elevation, e <= 0 {
            return HealthVerdict(level: .caution, title: "Signal, but not this satellite", detail: "\(strength) on frequency, but the satellite is below the horizon. Probably another transmitter.")
        }
        if r.onFrequency {
            let width = r.widthHz >= 1000 ? String(format: "%.0f kHz wide", r.widthHz / 1000) : "narrow"
            let offset = abs(r.peakOffsetHz) >= 1000 ? String(format: ", %+.0f kHz off centre", r.peakOffsetHz / 1000) : ""
            if mode == .listen {
                return HealthVerdict(level: .caution, title: "Signal, not decoding yet", detail: "\(strength), \(width)\(offset). The decoder hasn't locked on to it.")
            }
            return HealthVerdict(level: .good, title: "Signal present", detail: "\(strength), \(width)\(offset). Only decoding can prove it holds data.")
        }
        if r.elsewhere {
            return HealthVerdict(level: .caution, title: "Signal off frequency", detail: String(format: "%@ at %+.0f kHz, too far off to be this satellite. Probably another transmitter.", strength, r.peakOffsetHz / 1000))
        }
        if let e = elevation, e <= 0 {
            return HealthVerdict(level: .bad, title: "Only noise", detail: "The satellite is below this location's horizon, so this is just noise.")
        }
        if noiseSeconds < noiseGrace {
            return HealthVerdict(level: .caution, title: "No signal yet", detail: "Only noise so far.")
        }
        return HealthVerdict(level: .bad, title: "Only noise", detail: "No signal for \(Int(noiseSeconds)) s. This recording may not be worth keeping.")
    }
}

/// Watches a capture as it runs, and keeps a short history of how it went.
@MainActor
final class HealthMonitor: ObservableObject {
    @Published private(set) var verdict = HealthVerdict(level: .unknown, title: "Idle", detail: "")
    @Published private(set) var history: [HealthLevel] = []
    @Published private(set) var isActive = false
    @Published private(set) var noiseSeconds: TimeInterval = 0
    /// Set by the app: the health check needs to know if the satellite could be heard at all.
    var elevation: Double?
    /// Share of the expected samples reaching the file. Only raw recordings can measure this.
    var arrival: Double?

    private var frames: [[Float]] = []
    private var frequency = 0.0
    private var sampleRate = 0.0
    private var mode = CaptureMode.record
    private var framesLocked = false
    private var last: Date?
    private var counter = 0
    private var goodSeconds: TimeInterval = 0
    private var totalSeconds: TimeInterval = 0
    private var bucketLevels: [HealthLevel] = []
    private var bucketStart = Date()

    private static let keepFrames = 30
    private static let bucketSeconds: TimeInterval = 5
    private static let maxHistory = 72

    /// Share of the capture so far that held a signal or data.
    var goodPercent: Int? { totalSeconds >= 5 ? Int((goodSeconds / totalSeconds * 100).rounded()) : nil }

    func begin(frequency: Double, sampleRate: Double, mode: CaptureMode) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.mode = mode
        frames = []
        framesLocked = false
        arrival = nil
        last = nil
        counter = 0
        goodSeconds = 0
        totalSeconds = 0
        noiseSeconds = 0
        history = []
        bucketLevels = []
        bucketStart = Date()
        isActive = true
        verdict = HealthVerdict(level: .unknown, title: "Analysing", detail: "Waiting for enough signal to judge.")
    }

    /// The verdict stays up afterwards, so it can still be read once a capture stops.
    func end() { isActive = false }

    func update(fft: [Float], framesLocked locked: Bool) {
        guard isActive, !fft.isEmpty else { return }
        framesLocked = locked
        frames.append(fft)
        if frames.count > Self.keepFrames { frames.removeFirst(frames.count - Self.keepFrames) }
        counter += 1
        // About two seconds' worth is the least that says anything, and it needn't run on every frame.
        guard frames.count >= 4, counter % 4 == 0 else { return }

        let now = Date()
        let step = last.map { now.timeIntervalSince($0) } ?? 0
        last = now
        let reading = SpectrumReading.analyse(frames: frames, frequency: frequency, sampleRate: sampleRate)
        // A signal can't be this satellite while it's below the horizon.
        let isSignal = locked || (reading?.onFrequency == true && (elevation ?? 1) > 0)
        noiseSeconds = isSignal || reading?.elsewhere == true || reading?.onFrequency == true ? 0 : noiseSeconds + step
        totalSeconds += step
        if isSignal { goodSeconds += step }

        let v = HealthVerdict.judge(reading: reading, mode: mode, framesLocked: locked, elevation: elevation, noiseSeconds: noiseSeconds, arrival: arrival)
        if v != verdict { verdict = v }
        bucketLevels.append(v.level)
        if now.timeIntervalSince(bucketStart) >= Self.bucketSeconds {
            // A bucket reads as its best moment: a burst of signal mustn't be lost among noise.
            let best = bucketLevels.contains(.good) ? HealthLevel.good : bucketLevels.contains(.caution) ? .caution : bucketLevels.contains(.bad) ? .bad : .unknown
            history.append(best)
            if history.count > Self.maxHistory { history.removeFirst() }
            bucketLevels = []
            bucketStart = now
        }
    }
}
