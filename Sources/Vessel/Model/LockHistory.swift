import Foundation

/// Every satellite locked, newest first, kept on disk until cleared.
@MainActor
final class LockHistory: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let norad: Int
        let name: String
        let countryISO: String
        let date: Date
    }

    nonisolated static let limit = 500
    /// Locking the same satellite again this soon counts as the same visit.
    nonisolated static let sameVisit: TimeInterval = 120

    @Published private(set) var entries: [Entry]
    private let file: URL?

    init(file: URL? = AppFolders.isTesting ? nil : Res.cacheDir.appendingPathComponent("lock_history.json")) {
        self.file = file
        entries = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.decoder.decode([Entry].self, from: $0) } ?? []
    }

    func record(_ sat: Satellite, at date: Date = Date()) {
        entries = Self.adding(Entry(norad: sat.norad, name: sat.name, countryISO: sat.countryISO, date: date), to: entries)
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    nonisolated static func adding(_ e: Entry, to list: [Entry]) -> [Entry] {
        var list = list
        if let last = list.first, last.norad == e.norad, e.date.timeIntervalSince(last.date) < sameVisit {
            list.removeFirst()
        }
        list.insert(e, at: 0)
        return Array(list.prefix(limit))
    }

    /// Grouped by day, newest day first.
    nonisolated static func days(_ list: [Entry], calendar: Calendar = .current) -> [(day: Date, entries: [Entry])] {
        let groups = Dictionary(grouping: list) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private func save() {
        guard let file, let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
