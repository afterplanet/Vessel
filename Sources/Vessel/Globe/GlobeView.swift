import SwiftUI
import MetalKit

/// Steps every satellite on a background queue and hands the renderer a ready-made GPU buffer.
final class Propagator {
    private let queue = DispatchQueue(label: "vessel.propagator", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var sats: [Satellite] = []
    private var index: [Int: Int] = [:]
    private let lock = NSLock()

    func setSatellites(_ s: [Satellite]) {
        let map = Dictionary(s.enumerated().map { ($1.norad, $0) }, uniquingKeysWith: { a, _ in a })
        lock.lock(); sats = s; index = map; lock.unlock()
    }

    func start(device: MTLDevice, publish: @escaping (StateFrame) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let list = self.sats; let map = self.index; self.lock.unlock()
            guard !list.isEmpty else { return }
            if let f = Self.step(list, map, device: device) { publish(f) }
        }
        t.resume()
        timer = t
    }

    private static func step(_ list: [Satellite], _ map: [Int: Int], device: MTLDevice) -> StateFrame? {
        let n = list.count
        guard let buf = device.makeBuffer(length: n * MemoryLayout<ParticleVertex>.stride, options: .storageModeShared) else { return nil }
        let wall = CACurrentMediaTime()
        let jd = Astro.julianDate()
        var pos = [SIMD3<Float>](repeating: .zero, count: n)
        var vel = [SIMD3<Float>](repeating: .zero, count: n)
        let verts = buf.contents().bindMemory(to: ParticleVertex.self, capacity: n)
        let scale = 1 / Astro.earthRadiusKm
        pos.withUnsafeMutableBufferPointer { pp in
            vel.withUnsafeMutableBufferPointer { vp in
                let pb = pp.baseAddress!, vb = vp.baseAddress!
                let chunks = 8, per = n / chunks + 1
                let (p0, v0, out) = (pb, vb, verts)
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    for i in (c * per)..<min(n, (c + 1) * per) {
                        let sat = list[i]
                        guard let st = sat.state(jd: jd) else {
                            p0[i] = SIMD3(.nan, 0, 0)
                            // A class of -1 hides it: this object has decayed in the model.
                            out[i] = ParticleVertex(px: 0, py: 0, pz: 0, vx: 0, vy: 0, vz: 0, r: 0, g: 0, b: 0, a: -1)
                            continue
                        }
                        var r = SIMD3<Float>(st.r * scale), v = SIMD3<Float>(st.v * scale)
                        // Too far off for the view, so these sit in a shell at their true bearing.
                        if sat.ephemeris != nil {
                            let km = simd_length(st.r)
                            let shell = 3.2 + 0.6 * log10(max(km, 10_000) / 10_000)
                            r = SIMD3<Float>(simd_normalize(st.r) * shell)
                            v = .zero
                        }
                        p0[i] = r; v0[i] = v
                        let c = Palette.color(sat.orbit)
                        out[i] = ParticleVertex(px: r.x, py: r.y, pz: r.z, vx: v.x, vy: v.y, vz: v.z, r: c.x, g: c.y, b: c.z, a: sat.filteredOut ? -1 : Float(sat.orbit.index))
                    }
                }
            }
        }
        return StateFrame(buffer: buf, count: n, jd: jd, wallTime: wall, sats: list, indexByNorad: map, pos: pos, vel: vel)
    }
}

/// Small name tag that follows a point on the globe.
final class TagView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        addSubview(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, at p: CGPoint, in bounds: CGRect) {
        if label.stringValue != text {
            label.stringValue = text
            label.sizeToFit()
        }
        let s = label.frame.size
        var o = CGPoint(x: p.x + 14, y: p.y + 10)
        if o.x + s.width + 16 > bounds.maxX { o.x = p.x - s.width - 30 }
        if o.y + s.height + 8 > bounds.maxY { o.y = p.y - s.height - 18 }
        frame = CGRect(x: o.x, y: o.y, width: s.width + 16, height: s.height + 7)
        label.frame.origin = CGPoint(x: 8, y: 3.5)
        isHidden = false
    }
}

final class GlobeNSView: MTKView {
    var renderer: GlobeRenderer?
    var onLock: ((Satellite) -> Void)?
    var onHover: ((Satellite?) -> Void)?
    var onUserDrag: (() -> Void)?
    var onPickLocation: ((Double, Double) -> Void)?
    /// While on, the next click sets the address instead of locking a satellite.
    var pickMode = false {
        didSet {
            guard pickMode != oldValue else { return }
            if pickMode {
                hovered = nil
                renderer?.hoveredNorad = nil
                hoverTag.isHidden = true
            }
            (pickMode ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }
    private var tracking: NSTrackingArea?
    private var downPoint: CGPoint?
    private var dragged = false
    private var lastMove: CFTimeInterval = 0
    let hoverTag = TagView()
    let lockTag = TagView()
    var lockedName: String?
    private var hovered: Satellite?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    func installTags() {
        addSubview(lockTag)
        addSubview(hoverTag)
    }

    func updateHover(_ p: CGPoint) {
        if pickMode { NSCursor.crosshair.set(); return }
        let hit = renderer?.pick(at: p)
        if hit?.norad != hovered?.norad {
            hovered = hit
            renderer?.hoveredNorad = hit?.norad
            onHover?(hit)
            if hit != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        if let hit { hoverTag.show(hit.name, at: p, in: bounds) } else { hoverTag.isHidden = true }
    }

    override func mouseMoved(with event: NSEvent) {
        let now = CACurrentMediaTime()
        guard now - lastMove > 1.0 / 45 else { return }
        lastMove = now
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        renderer?.hoveredNorad = nil
        hoverTag.isHidden = true
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
        dragged = false
        renderer?.lonVel = 0; renderer?.latVel = 0
        renderer?.cancelFly()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let r = renderer else { return }
        dragged = true
        onUserDrag?()
        // Ground under the cursor tracks the drag, as in Google Earth.
        // Scaled to altitude and view height, so the ground stays under the cursor at any zoom.
        let k = (r.distance - 1) * 0.055 * 800 / Float(max(bounds.height, 1))
        let dLon = Float(-event.deltaX) * k, dLat = Float(event.deltaY) * k
        r.lon += dLon
        r.lat = max(-89, min(89, r.lat + dLat))
        r.lonVel = dLon * 0.6
        r.latVel = dLat * 0.6
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard !dragged, let down = downPoint else { return }
        if event.clickCount == 2 {
            renderer?.targetDistance = max(Self.closest, 1 + (renderer!.targetDistance - 1) * 0.5)
            return
        }
        if pickMode {
            if let spot = renderer?.surfacePoint(at: down) { onPickLocation?(spot.lat, spot.lon) }
            return
        }
        if let s = renderer?.pick(at: down, radius: 11) { onLock?(s) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let r = renderer else { return }
        let amount = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.0045 : event.scrollingDeltaY * 0.04)
        r.targetDistance = zoom(r.targetDistance, by: exp(-amount))
    }

    override func magnify(with event: NSEvent) {
        guard let r = renderer else { return }
        r.targetDistance = zoom(r.targetDistance, by: exp(-Float(event.magnification) * 1.4))
    }

    /// Zoom works on altitude, so it stays gentle close to the ground.
    private func zoom(_ d: Float, by f: Float) -> Float { max(Self.closest, min(40, 1 + (d - 1) * f)) }

    /// About 10 km up, where the imagery's 10 m pixels fill the screen.
    static let closest: Float = 1.0016

    func refreshTags() {
        if let n = renderer?.lockedNorad, let name = lockedName, let p = renderer?.screenPoint(norad: n) {
            lockTag.show(name, at: p, in: bounds)
        } else {
            lockTag.isHidden = true
        }
    }
}

struct GlobeView: NSViewRepresentable {
    @EnvironmentObject var store: SatelliteStore
    @EnvironmentObject var app: AppState

    final class Coordinator {
        let propagator = Propagator()
        var renderer: GlobeRenderer?
        var version = -1
        var watchdog: Timer?
        var attempts = 0
        var lastFrames = 0
        var stalledSeconds = 0
        deinit { watchdog?.invalidate() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GlobeNSView {
        let v = GlobeNSView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        if Snapshot.arguments.contains("--snapshot") || Snapshot.arguments.contains("--test-zoom") || Snapshot.arguments.contains("--test-marker") { v.framebufferOnly = false }
        v.installTags()
        attach(v, context.coordinator)
        // Once a second: finish a failed setup, and restart drawing if it has stalled.
        let c = context.coordinator
        c.watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak v, weak c] _ in
            MainActor.assumeIsolated {
                guard let v, let c else { return }
                if c.renderer == nil { attach(v, c); return }
                guard let r = c.renderer else { return }
                // Hidden windows don't draw, and that's not a fault.
                let visible = v.window?.isVisible == true && v.window?.occlusionState.contains(.visible) == true && v.bounds.width > 0
                // Nor does one paused on purpose, behind a spacecraft's own view.
                if !visible || v.isPaused || r.framesDrawn != c.lastFrames {
                    c.lastFrames = r.framesDrawn
                    c.stalledSeconds = 0
                    return
                }
                c.stalledSeconds += 1
                if c.stalledSeconds >= 3 {
                    NSLog("Vessel: restarting globe drawing after a stall")
                    c.stalledSeconds = 0
                    v.isPaused = true
                    v.isPaused = false
                    v.releaseDrawables()
                }
            }
        }
        return v
    }

    private func attach(_ v: GlobeNSView, _ c: Coordinator) {
        c.attempts += 1
        guard let r = GlobeRenderer(view: v) else {
            if c.attempts >= 5 { app.globeProblem = "The globe couldn't start on this Mac's graphics hardware." }
            return
        }
        app.globeProblem = nil
        c.renderer = r
        v.renderer = r
        v.delegate = r
        r.onDrawn = { [weak v] in v?.refreshTags() }
        r.onTexturesReady = { app.globeReady = true; app.globeProblem = nil }
        r.onTextureProblem = { n in if n >= 3 { app.globeProblem = "Still trying to load the Earth images…" } }
        v.onLock = { sat in Task { @MainActor in app.lock(sat) } }
        v.onPickLocation = { lat, lon in Task { @MainActor in app.pickLocation(lat: lat, lon: lon) } }
        v.onUserDrag = { Task { @MainActor in if app.followLocked { app.followLocked = false } } }
        app.renderer = r
        c.propagator.start(device: r.device) { [weak r] f in r?.publish(f) }
        app.flyToStation()
    }

    func updateNSView(_ v: GlobeNSView, context: Context) {
        if context.coordinator.version != store.catalogVersion {
            context.coordinator.version = store.catalogVersion
            context.coordinator.propagator.setSatellites(store.satellites)
        }
        guard let r = context.coordinator.renderer else { return }
        // Nothing to draw it for while a spacecraft's own view covers it.
        v.isPaused = app.spaceObject != nil
        r.lockedNorad = app.locked?.norad
        v.lockedName = app.locked?.name
        r.follow = app.followLocked
        r.orbitFilter = app.orbitFilter
        r.shownCount = store.shownCount(of: app.orbitFilter)
        r.totalCount = store.satellites.count
        v.pickMode = app.pickingLocation || app.pickingHostRegion
        r.regionPoint = app.hostRegion.map { s in
            let la = Float(s.lat * .pi / 180), lo = Float(s.lon * .pi / 180)
            return SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la)) * 1.00003
        }
        if let s = app.station {
            let la = Float(s.lat * .pi / 180), lo = Float(s.lon * .pi / 180)
            r.stationPoint = SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la)) * 1.00003
        } else {
            r.stationPoint = nil
        }
    }
}
