import AppKit
import SwiftUI
import Foundation

/// Follows the audio file the engine writes during a capture and decodes any SSTV pictures in it,
/// whether or not the speaker is on. Finished pictures are saved beside the audio as PNGs.
@MainActor
final class SSTVMonitor: ObservableObject {
    struct Finished: Identifiable {
        let id = UUID()
        let file: URL
        let image: CGImage
        let title: String
    }

    @Published private(set) var live: CGImage?
    @Published private(set) var liveTitle: String?
    @Published private(set) var liveRows = 0
    @Published private(set) var liveHeight = 0
    @Published private(set) var finished: [Finished] = []
    @Published private(set) var isFollowing = false

    private let worker = Worker()
    private var folder: URL?

    func follow(_ next: URL?) {
        guard next != folder else { return }
        folder = next
        isFollowing = next != nil
        if next != nil {
            finished = []
            live = nil
            liveTitle = nil
        }
        worker.follow(next) { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
    }

    private func apply(_ update: Worker.Update) {
        switch update {
        case .progress(let image, let title, let rows, let height):
            live = image
            liveTitle = title
            liveRows = rows
            liveHeight = height
        case .saved(let file, let image, let title):
            finished.insert(Finished(file: file, image: image, title: title), at: 0)
            live = nil
            liveTitle = nil
        }
    }

    /// Reads and decodes off the main thread. Only touched from its own queue.
    private final class Worker: @unchecked Sendable {
        enum Update: @unchecked Sendable {
            case progress(CGImage, String, Int, Int)
            case saved(URL, CGImage, String)
        }
        private let queue = DispatchQueue(label: "Vessel.sstv")
        private var folder: URL?
        private var timer: DispatchSourceTimer?
        private var tail: WavTail?
        private var decoder: SSTVDecoder?
        private var lastRows = -1
        private var send: ((Update) -> Void)?

        func follow(_ next: URL?, send: @escaping (Update) -> Void) {
            queue.async { [self] in
                closeOut()
                folder = next
                self.send = send
                guard let next else { return }
                tail = WavTail(folder: next)
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: 0.25)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }

        /// Reads what's left, since a picture may have just finished, and saves what there is.
        private func closeOut() {
            timer?.cancel()
            timer = nil
            if tail != nil { tick() }
            decoder?.finish()
            decoder = nil
            tail = nil
            lastRows = -1
        }

        private func tick() {
            guard let tail, let samples = tail.read(), let format = tail.format else { return }
            if decoder == nil {
                let d = SSTVDecoder(sampleRate: format.sampleRate)
                d.onFinished = { [weak self] picture in self?.save(picture) }
                decoder = d
            }
            guard let decoder else { return }
            decoder.feed(samples)
            if let picture = decoder.current, picture.rows != lastRows, let image = picture.image {
                lastRows = picture.rows
                send?(.progress(image, title(of: picture), picture.rows, picture.mode.height))
            }
        }

        private func title(of picture: SSTVPicture) -> String {
            picture.mode.name + (picture.joinedPartway ? ", joined partway" : "")
        }

        private func save(_ picture: SSTVPicture) {
            guard let folder, let image = picture.image else { return }
            let clock = DateFormatter()
            clock.dateFormat = "HHmmss"
            let name = "sstv_\(picture.mode.name.replacingOccurrences(of: " ", with: "_"))_\(clock.string(from: picture.started)).png"
            let url = folder.appendingPathComponent(name)
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            lastRows = -1
            send?(.saved(url, image, title(of: picture)))
        }
    }
}

/// The picture as it comes in, and the ones already received.
struct SSTVPanel: View {
    @ObservedObject var monitor: SSTVMonitor
    let expecting: Bool

    var body: some View {
        if monitor.live != nil || !monitor.finished.isEmpty || (expecting && monitor.isFollowing) {
            VStack(alignment: .leading, spacing: 4) {
                if let live = monitor.live, let title = monitor.liveTitle {
                    Image(decorative: live, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("\(title): row \(monitor.liveRows) of \(monitor.liveHeight)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                } else if monitor.finished.isEmpty {
                    Label("Waiting for an SSTV picture to start", systemImage: "photo")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(monitor.finished) { picture in
                    Button { NSWorkspace.shared.open(picture.file) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Image(decorative: picture.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text("\(picture.title), saved").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open \(picture.file.lastPathComponent)")
                }
            }
        }
    }
}
