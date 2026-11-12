import SwiftUI
import AVFoundation

/// Keeps the pass list for the locked satellite, the pass chosen for the sky plot, and spoken alerts.
@MainActor
final class PassPlanner: ObservableObject {
    @Published private(set) var passes: [SatPass] = []
    @Published private(set) var isWorking = false
    @Published var selected: SatPass?
    @Published var announce = UserDefaults.standard.bool(forKey: "passes.announce") {
        didSet { UserDefaults.standard.set(announce, forKey: "passes.announce") }
    }
    @Published var minutesBefore = UserDefaults.standard.object(forKey: "passes.minutesBefore") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(minutesBefore, forKey: "passes.minutesBefore") }
    }
    @Published var minElevation = UserDefaults.standard.object(forKey: "passes.minElevation") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(minElevation, forKey: "passes.minElevation"); recompute() }
    }

    private var satellite: Satellite?
    /// Which satellite `passes` belongs to, so a view never draws one satellite's passes for another.
    var satelliteID: Int? { satellite?.norad }
    private var station: Station?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var spoken = Set<String>()
    private let voice = AVSpeechSynthesizer()
    private var computedAt = Date.distantPast
    /// Set by tests to capture what would be said.
    var onSpeak: ((String) -> Void)?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func update(satellite: Satellite?, station: Station?) {
        guard satellite?.norad != self.satellite?.norad || station != self.station else { return }
        self.satellite = satellite
        self.station = station
        selected = nil
        spoken = []
        recompute()
    }

    private struct Box: @unchecked Sendable { let sat: Satellite }

    func recompute() {
        task?.cancel()
        guard let sat = satellite, let st = station, let copy = sat.clone() else { passes = []; isWorking = false; return }
        isWorking = true
        let box = Box(sat: copy)
        let minEl = minElevation
        task = Task.detached(priority: .utility) { [weak self] in
            let found = PassPredictor.passes(box.sat, lat: st.lat, lon: st.lon, hours: 48, minElevation: minEl) { Task.isCancelled }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.passes = found
                self.isWorking = false
                self.computedAt = Date()
                if let s = self.selected, !found.contains(s) { self.selected = nil }
            }
        }
    }

    /// The words for an alert, kept apart from the speaking so it can be tested.
    nonisolated static func message(name: String, pass: SatPass, minutes: Int) -> String {
        let spokenName = name.replacingOccurrences(of: "(", with: ", ").replacingOccurrences(of: ")", with: "")
        let height = "reaching \(Int(pass.maxElevation.rounded())) degrees"
        return minutes > 0 ? "\(spokenName) rises in \(minutes) minute\(minutes == 1 ? "" : "s"), \(height)."
                           : "\(spokenName) is rising now, \(height)."
    }

    func tick(now: Date = Date()) {
        // Passes go stale as time moves on and orbits update.
        if !isWorking, satellite != nil, now.timeIntervalSince(computedAt) > 1800 { recompute() }
        if let first = passes.first, first.los < now { passes.removeFirst() }
        guard announce, let sat = satellite, let next = passes.first(where: { $0.los > now }) else { return }
        let wait = next.aos.timeIntervalSince(now)
        var due: (key: String, minutes: Int)?
        if minutesBefore > 0, wait <= Double(minutesBefore) * 60, wait > Double(minutesBefore) * 60 - 20 {
            due = ("\(sat.norad)-\(next.aos.timeIntervalSince1970)-before", minutesBefore)
        } else if wait <= 0, wait > -20 {
            due = ("\(sat.norad)-\(next.aos.timeIntervalSince1970)-aos", 0)
        }
        guard let due, spoken.insert(due.key).inserted else { return }
        say(Self.message(name: sat.name, pass: next, minutes: due.minutes))
    }

    func say(_ text: String) {
        if let onSpeak { onSpeak(text); return }
        voice.speak(AVSpeechUtterance(string: text))
    }
}
