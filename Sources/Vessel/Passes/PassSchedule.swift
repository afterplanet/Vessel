import SwiftUI

struct ScheduledPass: Identifiable, Equatable {
    var id: String { "\(norad)-\(pass.aos.timeIntervalSince1970)" }
    let norad: Int
    let name: String
    let pass: SatPass
}

/// Follows the passes of a watch list of satellites: locks each one as it rises, so automatic
/// listening captures it, then moves to the next. Earlier in the list means higher priority.
@MainActor
final class PassSchedule: ObservableObject {
    @Published private(set) var watch: [Int] = (UserDefaults.standard.array(forKey: "schedule.watch") as? [Int]) ?? [] {
        didSet { UserDefaults.standard.set(watch, forKey: "schedule.watch") }
    }
    @Published private(set) var entries: [ScheduledPass] = []
    @Published private(set) var isWorking = false
    /// Always starts off: following a schedule is something to switch on deliberately.
    @Published var isOn = false { didSet { if isOn { note = nil; tick() } } }
    @Published private(set) var active: ScheduledPass?
    @Published private(set) var next: ScheduledPass?
    @Published private(set) var note: String?
    @Published var minElevation = UserDefaults.standard.object(forKey: "schedule.minElevation") as? Double ?? 10 {
        didSet { UserDefaults.standard.set(minElevation, forKey: "schedule.minElevation"); recompute() }
    }

    private weak var store: SatelliteStore?
    private weak var app: AppState?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var expectedLock: Int?
    private var computedAt = Date.distantPast
    private var station: Station?
    /// A satellite stays tuned this long after it sets, for signals that arrive late.
    static let holdAfterLOS: TimeInterval = 30

    func attach(store: SatelliteStore, app: AppState) {
        self.store = store
        self.app = app
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        recompute()
    }

    func name(_ norad: Int) -> String { store?.satellite(norad: norad)?.name ?? "NORAD \(norad)" }

    func add(_ sat: Satellite) {
        guard !watch.contains(sat.norad) else { return }
        watch.append(sat.norad)
        recompute()
    }

    func remove(_ norad: Int) {
        watch.removeAll { $0 == norad }
        if watch.isEmpty { isOn = false }
        recompute()
    }

    func moveUp(_ norad: Int) {
        guard let i = watch.firstIndex(of: norad), i > 0 else { return }
        watch.swapAt(i, i - 1)
    }

    private struct Box: @unchecked Sendable { let sats: [(Int, String, Satellite)] }

    func recompute() {
        task?.cancel()
        guard let store, let st = app?.station, !watch.isEmpty else { entries = []; isWorking = false; return }
        station = st
        let copies = watch.compactMap { n -> (Int, String, Satellite)? in
            guard let s = store.satellite(norad: n), let c = s.clone() else { return nil }
            return (n, s.name, c)
        }
        isWorking = true
        let box = Box(sats: copies)
        let minEl = minElevation
        task = Task.detached(priority: .utility) { [weak self] in
            var all: [ScheduledPass] = []
            for (n, name, sat) in box.sats {
                if Task.isCancelled { return }
                all += PassPredictor.passes(sat, lat: st.lat, lon: st.lon, hours: 48, minElevation: minEl) { Task.isCancelled }
                    .map { ScheduledPass(norad: n, name: name, pass: $0) }
            }
            let sorted = all.sorted { $0.pass.aos < $1.pass.aos }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.entries = sorted
                self?.isWorking = false
                self?.computedAt = Date()
            }
        }
    }

    /// Which pass to be on now, and which comes after. A pass in progress is never cut short for
    /// another; otherwise the highest-priority satellite that's up wins.
    nonisolated static func choose(_ entries: [ScheduledPass], now: Date, priority: [Int], current: ScheduledPass?)
        -> (active: ScheduledPass?, next: ScheduledPass?) {
        func rank(_ e: ScheduledPass) -> Int { priority.firstIndex(of: e.norad) ?? .max }
        let up = entries.filter { $0.pass.aos <= now && now < $0.pass.los }
        var active: ScheduledPass?
        if let current, up.contains(current) { active = current }
        else { active = up.min { (rank($0), $0.pass.aos) < (rank($1), $1.pass.aos) } }
        let next = entries.filter { $0.pass.aos > now }.min { $0.pass.aos < $1.pass.aos }
        return (active, next)
    }

    /// The satellite that should be locked: the active pass's, the one that just set for a short
    /// while, and otherwise the next one, tuned ahead of time.
    nonisolated static func target(active: ScheduledPass?, next: ScheduledPass?, lastEnded: ScheduledPass?, now: Date) -> Int? {
        if let active { return active.norad }
        if let lastEnded, now.timeIntervalSince(lastEnded.pass.los) < holdAfterLOS { return lastEnded.norad }
        return next?.norad
    }

    private var lastEnded: ScheduledPass?

    func tick(now: Date = Date()) {
        guard let app, let store else { return }
        if app.station != station { recompute() }
        if !isWorking, !watch.isEmpty, now.timeIntervalSince(computedAt) > 1800 { recompute() }
        entries.removeAll { $0.pass.los.addingTimeInterval(Self.holdAfterLOS) < now }

        let picked = Self.choose(entries, now: now, priority: watch, current: active)
        if let was = active, picked.active != was { lastEnded = was }
        if picked.active != active { active = picked.active }
        if picked.next != next { next = picked.next }
        guard isOn else { return }

        // Someone locking a different satellite by hand takes over from the schedule.
        if let expected = expectedLock, let locked = app.locked?.norad, locked != expected {
            isOn = false
            expectedLock = nil
            note = "Schedule stopped because you chose another satellite."
            return
        }
        guard let want = Self.target(active: active, next: next, lastEnded: lastEnded, now: now),
              let sat = store.satellite(norad: want) else { return }
        if app.locked?.norad != want {
            expectedLock = want
            app.lock(sat)
        } else {
            expectedLock = want
        }
    }
}

/// Watch list, the switch, and what's being followed now and next.
struct ScheduleSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var schedule: PassSchedule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if schedule.watch.isEmpty {
                Text("Add satellites to follow their passes one after another.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(schedule.watch.enumerated()), id: \.element) { i, n in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 14, alignment: .trailing)
                        Text(schedule.name(n)).lineLimit(1)
                        Spacer(minLength: 2)
                        if i > 0 {
                            Button { schedule.moveUp(n) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless).help("Higher priority when passes overlap")
                        }
                        Button { schedule.remove(n) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove from the schedule")
                    }
                }
            }
            Button {
                if let s = app.locked { schedule.add(s) }
            } label: {
                Label(app.locked.map { "Add \($0.name)" } ?? "Lock a satellite to add it", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(app.locked == nil || app.locked.map { schedule.watch.contains($0.norad) } == true)

            if !schedule.watch.isEmpty {
                Divider()
                Toggle("Follow the schedule", isOn: $schedule.isOn).controlSize(.small)
                    .disabled(app.station == nil)
                Stepper("Skip passes below \(Int(schedule.minElevation))°", value: $schedule.minElevation, in: 0...40, step: 5).controlSize(.small)
                if app.station == nil {
                    Text("Set a location first.").foregroundStyle(.secondary)
                } else {
                    status
                }
                if schedule.isOn, !app.autoListen {
                    Text("Listen automatically is off, so passes are tracked but not captured.")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let note = schedule.note { Text(note).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                if let a = schedule.active {
                    line("Active", "\(a.name), sets in \(Self.wait(a.pass.los))", .green)
                } else {
                    line("Active", schedule.isWorking ? "Working out passes…" : "None", .secondary)
                }
                if let n = schedule.next {
                    line("Next", "\(n.name) in \(Self.wait(n.pass.aos)), up to \(Int(n.pass.maxElevation))°", .primary)
                } else if !schedule.isWorking {
                    line("Next", "Nothing in 48 hours", .secondary)
                }
                let later = schedule.entries.filter { $0.pass.aos > Date() }.dropFirst().prefix(5)
                ForEach(Array(later)) { e in
                    HStack {
                        Text(e.pass.aos.formatted(.dateTime.weekday(.abbreviated).hour().minute())).monospacedDigit()
                        Text(e.name).lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(Int(e.pass.maxElevation))°").monospacedDigit()
                    }
                    .foregroundStyle(.secondary).font(.system(size: 10))
                }
            }
        }
    }

    private func line(_ label: String, _ value: String, _ colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(value).foregroundStyle(colour).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func wait(_ until: Date) -> String {
        let s = max(0, Int(until.timeIntervalSinceNow))
        return s < 60 ? "\(s) s" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
