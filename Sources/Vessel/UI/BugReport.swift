import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Bug reports go to GitHub Issues through the reporter's own browser, so Vessel never holds a
/// GitHub login. The page opens filled in; the images are put on the clipboard to paste into it.
enum BugReport {
    static let repository = "afterplanet/Vessel"
    /// GitHub turns away longer addresses, so the description is trimmed to fit.
    static let maxURLLength = 7_500
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "bmp", "webp"]

    struct Details: Equatable {
        var appVersion: String
        var macOS: String
        var model: String
        var receiver: String?
        var satellite: String?

        /// What's sent, and nothing else: no location, callsign or file paths.
        var lines: [String] {
            var out = ["Vessel \(appVersion)", "macOS \(macOS)", "Mac: \(model)"]
            if let receiver { out.append("Receiver: \(receiver)") }
            if let satellite { out.append("Locked satellite: \(satellite)") }
            return out
        }
    }

    static func currentDetails(receiver: String?, satellite: String?) -> Details {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development build"
        let build = info["CFBundleVersion"] as? String
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Details(appVersion: build.map { "\(version) (\($0))" } ?? version,
                       macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                       model: "\(sysctl("hw.model") ?? "Mac"), \(sysctl("machdep.cpu.brand_string") ?? "unknown chip")",
                       receiver: receiver, satellite: satellite)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: bytes).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func body(description: String, details: Details?, imageCount: Int) -> String {
        var parts = [description.trimmingCharacters(in: .whitespacesAndNewlines)]
        if imageCount > 0 {
            parts.append("<!-- \(imageCount) image\(imageCount == 1 ? "" : "s") to paste here with ⌘V -->")
        }
        if let details {
            parts.append("### System\n" + details.lines.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("_Sent from Vessel's Report a Bug window._")
        return parts.joined(separator: "\n\n")
    }

    /// GitHub's new-issue page, filled in. Returns whether the description had to be shortened.
    static func issueURL(title: String, description: String, details: Details?, imageCount: Int) -> (url: URL, trimmed: Bool) {
        var text = description
        var trimmed = false
        while true {
            var c = URLComponents(string: "https://github.com/\(repository)/issues/new")!
            c.queryItems = [URLQueryItem(name: "title", value: title.trimmingCharacters(in: .whitespacesAndNewlines)),
                            URLQueryItem(name: "body", value: body(description: text, details: details, imageCount: imageCount)),
                            URLQueryItem(name: "labels", value: "bug")]
            // `+` and `&` inside the text must not be read as separators.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let url = c.url!
            if url.absoluteString.count <= maxURLLength || text.isEmpty { return (url, trimmed) }
            trimmed = true
            let keep = max(0, text.count - max(50, (url.absoluteString.count - maxURLLength) / 3))
            text = String(text.prefix(keep)) + (keep > 0 ? "…" : "")
            if keep == 0 { text = "" }
        }
    }

    /// Copies the images into a folder of their own, with plain names, ready to paste or drag.
    static func stage(_ images: [URL]) -> [URL] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Vessel bug report \(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return images.enumerated().compactMap { i, src in
            let dest = dir.appendingPathComponent("image-\(i + 1).\(src.pathExtension.lowercased())")
            return (try? fm.copyItem(at: src, to: dest)) != nil ? dest : nil
        }
    }

    static func isImage(_ url: URL) -> Bool { imageTypes.contains(url.pathExtension.lowercased()) }
}

/// The button at the top right of the main window, right of the search field.
struct BugReportButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ladybug")
                .font(.system(size: 15))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Report a bug")
        .accessibilityLabel("Report a bug")
    }
}

/// Puts the button in the window's title bar at the far right. SwiftUI can only place toolbar items
/// after the search field from macOS 26, and this works on every version Vessel supports.
struct BugReportTitlebarButton: NSViewRepresentable {
    let action: () -> Void

    final class Probe: NSView {
        var action: () -> Void = {}
        static let identifier = NSUserInterfaceItemIdentifier("Vessel.bugReport")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == Self.identifier }) else { return }
            let host = NSHostingView(rootView: BugReportButton(action: { [weak self] in self?.action() }).padding(.trailing, 10))
            host.frame.size = host.fittingSize
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = Self.identifier
            accessory.view = host
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.action = action
        return p
    }

    func updateNSView(_ p: Probe, context: Context) { p.action = action }
}

struct BugReportSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var images: [URL] = []
    @State private var includeDetails = true
    @State private var dropTargeted = false
    @State private var sent: [URL]?
    @State private var trimmed = false

    private var details: BugReport.Details {
        BugReport.currentDetails(receiver: app.source.name, satellite: app.locked?.name)
    }

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sent { done(sent) } else { form }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Report a Bug", systemImage: "ladybug").font(.title3.weight(.semibold))
            Text("This opens a new issue on GitHub with what you write here filled in. You'll need a GitHub account to submit it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.callout.weight(.medium))
                TextField("Short summary, like \u{201C}Waterfall freezes after a pass\u{201D}", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened").font(.callout.weight(.medium))
                TextEditor(text: $text)
                    .font(.body)
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What you did, what you expected, and what happened instead.")
                                .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                        }
                    }
            }

            imagesSection

            Toggle(isOn: $includeDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include system details")
                    Text(details.lines.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue on GitHub") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Images (optional)").font(.callout.weight(.medium))
                Spacer()
                Button("Capture Screen…", action: capture).help("Drag over the part of the screen to include")
                Button("Add Images…", action: pick)
            }
            .controlSize(.small)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                if images.isEmpty {
                    Text("Drop screenshots here").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(images, id: \.self) { url in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                                        .resizable().scaledToFill()
                                        .frame(width: 72, height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
                                    Button { images.removeAll { $0 == url } } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain).padding(2).help("Remove")
                                }
                                .help(url.lastPathComponent)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: 72)
            .dropDestination(for: URL.self) { urls, _ in
                let add = urls.filter(BugReport.isImage).filter { !images.contains($0) }
                images += add
                return !add.isEmpty
            } isTargeted: { dropTargeted = $0 }
        }
    }

    private func done(_ staged: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Finish on GitHub", systemImage: "checkmark.circle").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Your browser has GitHub's new issue page open, already filled in. Sign in if it asks.")
                if !staged.isEmpty {
                    Text("2. Your \(staged.count == 1 ? "image is" : "\(staged.count) images are") on the clipboard. Click in the description and press ⌘V to add \(staged.count == 1 ? "it" : "them"). Or drag \(staged.count == 1 ? "it" : "them") in from the Finder window.")
                }
                Text("\(staged.isEmpty ? "2" : "3"). Click Submit new issue.")
                if trimmed {
                    Text("Your description was long, so the end was cut to fit GitHub's limit. Paste the rest in a comment.")
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !staged.isEmpty {
                    Button("Show Images in Finder") { NSWorkspace.shared.activateFileViewerSelecting(staged) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func send() {
        let (url, cut) = BugReport.issueURL(title: title, description: text, details: includeDetails ? details : nil, imageCount: images.count)
        let staged = BugReport.stage(images)
        if !staged.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(staged as [NSURL])
            NSWorkspace.shared.activateFileViewerSelecting(staged)
        }
        NSWorkspace.shared.open(url)
        trimmed = cut
        sent = staged
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { images += panel.urls.filter { !images.contains($0) } }
    }

    /// macOS's own screenshot tool, in drag-to-select mode.
    private func capture() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Vessel screenshot \(Int(Date().timeIntervalSince1970)).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", file.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: file.path) { images.append(file) }
            }
        }
        try? p.run()
    }
}
