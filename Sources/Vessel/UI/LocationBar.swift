import SwiftUI
import MapKit

/// Floating bar at the top of the globe: the selected address and its flag, a field with address
/// suggestions, and a button for picking the spot on the globe instead.
struct LocationBar: View {
    @EnvironmentObject var app: AppState
    @StateObject private var completer = LocationCompleter()
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                leadingIcon
                TextField(app.pickingLocation ? "Click anywhere on the globe" : app.locationLinkedToHost ? "Find a host near…" : "Type an address", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($focused)
                    .frame(width: 280)
                    .disabled(app.pickingLocation)
                    .onSubmit { if let first = completer.results.first { pick(first) } }
                    .onChange(of: text) { _, q in
                        if focused { completer.update(q) }
                    }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused {
                            completer.clear()
                            text = app.station?.name ?? ""
                        }
                    }
                if app.locationLinkedToHost {
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Linked to the public network: this follows the selected host, and searching picks the nearest one.")
                }
                Divider().frame(height: 16)
                Button {
                    focused = false
                    app.findMyLocation()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 13))
                        .foregroundStyle(app.findingMyLocation ? Color.white : Color.primary)
                        .frame(width: 24, height: 22)
                        .background(app.findingMyLocation ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.findingMyLocation)
                .help("Find my location: nearby Wi-Fi or your internet address, or by scanning GPS satellites with your receiver when there's neither")
                .accessibilityLabel("Find my location")
                Button {
                    focused = false
                    app.pickingLocation.toggle()
                } label: {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 13))
                        .foregroundStyle(app.pickingLocation ? Color.white : Color.primary)
                        .frame(width: 24, height: 22)
                        .background(app.pickingLocation ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(app.pickingLocation ? .cancelAction : nil)
                .help(app.pickingLocation ? "Cancel (Esc)" : app.locationLinkedToHost ? "Pick a spot, and use the nearest host" : "Pick the location on the globe")
            }
            .padding(.leading, 11).padding(.trailing, 6).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)

            if !completer.results.isEmpty || !shownSaved.isEmpty { suggestions }
            if let note = app.locationNote { noteRow(note) }
        }
        .fixedSize()
        .sheet(item: $app.gpsOffer) { GPSFixSheet(offer: $0) }
        .onAppear {
            text = app.station?.name ?? ""
            if let i = Snapshot.arguments.firstIndex(of: "--search-text"), Snapshot.arguments.indices.contains(i + 1) {
                completer.update(Snapshot.arguments[i + 1])
            }
        }
        .onChange(of: app.station) { _, st in
            if !focused { text = st?.name ?? "" }
        }
    }

    @ViewBuilder private var leadingIcon: some View {
        if app.findingAddress || app.findingMyLocation {
            ProgressView().controlSize(.small).frame(width: 20, height: 15)
        } else if let st = app.station, !st.iso.isEmpty {
            FlagView(iso: st.iso, height: 15)
        } else {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary).frame(width: 20, height: 15)
        }
    }

    /// Pinned places stay at the bottom of the search whatever's typed, until they're deleted.
    private var shownSaved: [SavedLocation] {
        focused || Snapshot.arguments.contains("--saved-open") ? app.savedLocations : []
    }

    private func noteRow(_ note: LocationNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: note.symbol).font(.system(size: 11))
                .foregroundStyle(note.isWarning ? Color.orange : Color.green).frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
                Text(note.text).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if note.offersGPSScan {
                    Button("Scan GPS Satellites") { app.scanGPSSatellites() }
                        .controlSize(.small)
                }
            }
            Button { app.closeLocationNote() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .frame(width: 356)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .transition(.opacity)
    }

    /// One list: addresses, then pinned places as the last records.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(completer.results, id: \.self) { r in
                Button { pick(r) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.system(size: 12)).lineLimit(1)
                        if !r.subtitle.isEmpty {
                            Text(r.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if r != completer.results.last || !shownSaved.isEmpty { Divider().padding(.leading, 11) }
            }
            ForEach(shownSaved) { place in
                pinnedRow(place)
                if place != shownSaved.last { Divider().padding(.leading, 11) }
            }
        }
        .frame(width: 356)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }

    private func pinnedRow(_ place: SavedLocation) -> some View {
        HStack(spacing: 6) {
            Button {
                focused = false
                app.useSaved(place)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name).font(.system(size: 12)).lineLimit(1)
                        Text("Pinned \(place.saved.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { app.removeSaved(place) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this pinned location")
            .accessibilityLabel("Delete \(place.name)")
        }
        .padding(.leading, 11).padding(.trailing, 7).padding(.vertical, 5)
    }

    private func pick(_ r: MKLocalSearchCompletion) {
        focused = false
        text = r.title
        completer.clear()
        Task {
            if let (name, coord, iso) = await completer.resolve(r) {
                app.setTypedLocation(name: name, coordinate: coord, iso: iso)
                app.flyToStation()
            }
        }
    }
}
