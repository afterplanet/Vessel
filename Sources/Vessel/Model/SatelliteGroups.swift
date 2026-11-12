import SwiftUI

/// Named lists of satellites you care about. A group can be shown alone on the globe, and
/// handed to the pass schedule.
@MainActor
final class SatelliteGroups: ObservableObject {
    struct Group: Codable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var norads: [Int]
    }

    @Published private(set) var groups: [Group] = [] { didSet { save() } }
    /// The group shown alone on the globe, by name.
    @Published var shown: String?
    private let key: String

    init(key: String = "satelliteGroups") {
        self.key = key
        if let d = UserDefaults.standard.data(forKey: key), let g = try? JSONDecoder().decode([Group].self, from: d) { groups = g }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(d, forKey: key) }
    }

    func group(_ name: String?) -> Group? { groups.first { $0.name == name } }

    /// Returns false if the name is empty or taken.
    @discardableResult func create(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, group(n) == nil else { return false }
        groups.append(Group(name: n, norads: []))
        return true
    }

    func delete(_ name: String) {
        groups.removeAll { $0.name == name }
        if shown == name { shown = nil }
    }

    func add(_ norad: Int, to name: String) {
        guard let i = groups.firstIndex(where: { $0.name == name }), !groups[i].norads.contains(norad) else { return }
        groups[i].norads.append(norad)
    }

    func remove(_ norad: Int, from name: String) {
        guard let i = groups.firstIndex(where: { $0.name == name }) else { return }
        groups[i].norads.removeAll { $0 == norad }
    }

    /// What the globe filter should keep: nil for everything.
    var shownNorads: Set<Int>? { group(shown).map { Set($0.norads) } }
}

struct GroupsSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore
    @ObservedObject var groups: SatelliteGroups
    @ObservedObject var schedule: PassSchedule
    @State private var selected: String?
    @State private var newName = ""

    private var current: SatelliteGroups.Group? { groups.group(selected) ?? groups.groups.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("New group name", text: $newName).textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(create)
                Button("Add", action: create).controlSize(.small).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let g = current {
                HStack {
                    Picker("", selection: Binding(get: { g.name }, set: { selected = $0 })) {
                        ForEach(groups.groups) { Text("\($0.name) (\($0.norads.count))").tag($0.name) }
                    }
                    .labelsHidden().controlSize(.small)
                    Button(role: .destructive) { groups.delete(g.name); selected = nil } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete this group")
                }
                ForEach(g.norads, id: \.self) { n in
                    HStack(spacing: 6) {
                        Button { if let s = store.satellite(norad: n) { app.lock(s) } } label: {
                            Text(store.satellite(norad: n)?.name ?? "NORAD \(n)").lineLimit(1)
                        }
                        .buttonStyle(.plain).help("Lock this satellite")
                        Spacer(minLength: 2)
                        Button { groups.remove(n, from: g.name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove from the group")
                    }
                }
                Button {
                    if let s = app.locked { groups.add(s.norad, to: g.name) }
                } label: {
                    Label(app.locked.map { "Add \($0.name)" } ?? "Lock a satellite to add it", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(app.locked == nil || app.locked.map { g.norads.contains($0.norad) } == true)
                Divider()
                Toggle("Show only this group on the globe", isOn: Binding(
                    get: { groups.shown == g.name },
                    set: { groups.shown = $0 ? g.name : nil }))
                    .controlSize(.small).disabled(g.norads.isEmpty)
                Button("Use this group for the schedule") {
                    for n in g.norads { if let s = store.satellite(norad: n) { schedule.add(s) } }
                }
                .controlSize(.small)
                .disabled(g.norads.isEmpty)
                .help("Adds these satellites to the pass schedule's watch list")
            } else {
                Text("Make a group to keep the satellites you follow together.").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
    }

    private func create() {
        if groups.create(newName) { selected = newName.trimmingCharacters(in: .whitespaces); newName = "" }
    }
}
