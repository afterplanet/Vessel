import SwiftUI

/// Toolbar clock, beside the satellite search. Drops down every satellite locked before, by day.
struct LockHistoryButton: View {
    @EnvironmentObject var app: AppState
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .help("Satellites you've locked before")
        .accessibilityLabel("Lock history")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LockHistoryList(history: app.lockHistory) { open = false }
        }
        .task {
            // For scripted checks: a popover can't open before its window is on screen.
            guard Snapshot.arguments.contains("--history-open") else { return }
            try? await Task.sleep(for: .seconds(20))
            open = true
        }
    }
}

struct LockHistoryList: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore
    @ObservedObject var history: LockHistory
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !history.entries.isEmpty {
                    Button("Clear") { history.clear() }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if history.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 24, weight: .light))
                    Text("Satellites you lock appear here").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(LockHistory.days(history.entries), id: \.day) { day in
                            Text(dayTitle(day.day))
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
                            ForEach(day.entries) { row($0) }
                        }
                    }
                    .padding(.bottom, 6)
                }
                // A scroll view in a popover shrinks to nothing, so it's given the height it needs.
                .frame(height: min(380, CGFloat(history.entries.count) * 38 + CGFloat(LockHistory.days(history.entries).count) * 26 + 8))
            }
        }
        .frame(width: 300)
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .complete, time: .omitted)
    }

    private func row(_ e: LockHistory.Entry) -> some View {
        let sat = store.satellite(norad: e.norad)
        return HStack(spacing: 8) {
            FlagView(iso: e.countryISO, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(sat?.name ?? e.name).font(.system(size: 12)).lineLimit(1)
                Text("NORAD \(String(e.norad))").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(e.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            Button { history.remove(e) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from history")
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(app.locked?.norad == e.norad ? Color.accentColor.opacity(0.2) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let sat else { return }
            app.lock(sat)
            close()
        }
        .opacity(sat == nil ? 0.5 : 1)
        .help(sat == nil ? "No longer in the catalogue" : "Lock \(e.name) again")
    }
}
