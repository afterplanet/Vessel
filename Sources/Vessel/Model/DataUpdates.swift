import Foundation
import SwiftUI

/// How old each downloaded dataset is, and a single place to refresh them.
@MainActor
final class DataUpdates: ObservableObject {
    struct Item: Identifiable {
        let title: String
        let detail: String
        let file: String
        /// Their sources ask clients not to fetch faster than this, or it simply isn't worth it.
        let freshFor: TimeInterval
        var id: String { file }
    }

    static let items = [
        Item(title: "Satellite orbits (TLE)", detail: "CelesTrak, published every 2 hours", file: "gp_active.json", freshFor: 7200),
        Item(title: "Frequencies", detail: "SatNOGS", file: "satnogs_transmitters.json", freshFor: 86400),
        Item(title: "Satellite catalogue", detail: "CelesTrak", file: "satcat.csv", freshFor: 7 * 86400),
        Item(title: "AMSAT mode list", detail: "AMSAT", file: "amsat_catalog.json", freshFor: 86400),
        Item(title: "Amateur satellite frequencies", detail: "AMSAT satellite index", file: "amsat_frequencies.json", freshFor: 86400),
        Item(title: "Operators, builders and mass", detail: "GCAT, Jonathan McDowell", file: "gcat_satcat.tsv", freshFor: 7 * 86400),
        Item(title: "Telemetry formats", detail: "SatNOGS community decoders", file: SatNOGSDecoderFiles.commitCache, freshFor: 86400),
        Item(title: "Spacecraft positions", detail: "NASA JPL Horizons", file: "horizons_pos_50463.json", freshFor: 86400),
        Item(title: "Spy hosts", detail: "Airspy directory", file: "spy_hosts.json", freshFor: 300),
        Item(title: "Web SDRs", detail: "sdr-list.xyz", file: "web_sdrs.json", freshFor: 300),
    ]

    /// Orbit data past this gives pass times that can be noticeably off.
    static let staleOrbitDays = 7.0

    @Published private(set) var isChecking = false
    @Published private(set) var lastResult: String?
    @Published private(set) var refreshTick = 0

    func touch() { refreshTick += 1 }

    static func age(of file: String, now: Date = Date()) -> TimeInterval? {
        let url = Res.cacheDir.appendingPathComponent(file)
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(date)
    }

    nonisolated static func words(age: TimeInterval) -> String {
        if age < 90 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 172_800 { return "\(Int(age / 3600)) hr ago" }
        return "\(Int(age / 86400)) days ago"
    }

    /// Fetches only what's due. A repeat check right after is free, and polite to the sources.
    func checkNow(store: SatelliteStore, app: AppState, runner: SatDumpRunner) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false; refreshTick += 1 }
        lastResult = "Checking…"
        let orbitsAge = Self.age(of: "gp_active.json") ?? .infinity
        var parts: [String] = []
        if orbitsAge >= 7200 {
            let updated = await store.reload(force: true)
            parts.append(updated ? "Satellite orbits updated" : "Couldn't reach CelesTrak, so orbits weren't updated")
        } else {
            parts.append("Satellite orbits are current")
            await store.refreshDue()
        }
        parts.append(await SatNOGSDecoderFiles.update().words)
        await app.refreshHosts()
        await runner.checkForPipelineUpdates()
        app.retune()
        if !runner.pipelineStatus.isEmpty { parts.append(runner.pipelineStatus) }
        lastResult = parts.joined(separator: ". ")
    }
}

/// The Data Updates window.
struct DataUpdatesView: View {
    @EnvironmentObject var updates: DataUpdates
    @EnvironmentObject var store: SatelliteStore
    @EnvironmentObject var app: AppState
    @EnvironmentObject var runner: SatDumpRunner

    private func row(_ item: DataUpdates.Item) -> some View {
        let age = DataUpdates.age(of: item.file)
        let due = (age ?? .infinity) >= item.freshFor
        return HStack(spacing: 8) {
            Image(systemName: age == nil ? "exclamationmark.circle" : due ? "clock" : "checkmark.circle.fill")
                .foregroundStyle(age == nil ? Color.orange : due ? Color.secondary : Color.green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(age.map(DataUpdates.words(age:)) ?? "Not downloaded").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data Updates").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(DataUpdates.items) { row($0) }
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Signal decoders").font(.system(size: 12, weight: .medium))
                        Text(runner.pipelineStatus.isEmpty ? "Checked at every start" : runner.pipelineStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .id(updates.refreshTick)
            Divider()
            SatNOGSKeySettings()
            Divider()
            if let oldest = store.oldestLockedEpochDays(app.locked) {
                Text(String(format: "%@: orbit measured %.1f days ago", app.locked?.name ?? "", oldest))
                    .font(.system(size: 11)).foregroundStyle(oldest > DataUpdates.staleOrbitDays ? Color.orange : Color.secondary)
            }
            HStack {
                if let result = updates.lastResult {
                    Text(result).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(updates.isChecking ? "Checking…" : "Check Now") {
                    Task { await updates.checkNow(store: store, app: app, runner: runner) }
                }
                .disabled(updates.isChecking)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task {
            // Ages move on while the window's open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                updates.touch()
            }
        }
    }
}
