import AppKit
import SceneKit
import SwiftUI
import simd

/// Which picture of a spacecraft's surroundings is showing.
enum SpaceFocus: Hashable {
    case solarSystem
    case near(SpaceObject.Centre)
    /// The Earth and Moon together, for something near the Moon.
    case earthAndMoon

    var title: String {
        switch self {
        case .solarSystem: "Solar system"
        case .near(let c): c == .earth ? "Near Earth" : "Near \(c.name)"
        case .earthAndMoon: "Earth and Moon"
        }
    }
}

extension SpaceObject {
    var focuses: [SpaceFocus] {
        switch centre {
        case .moon: [.near(.moon), .earthAndMoon, .solarSystem]
        case .earth: [.solarSystem, .near(.earth)]
        case .mars: [.solarSystem, .near(.mars)]
        case .jupiter: [.solarSystem, .near(.jupiter)]
        case nil: [.solarSystem]
        }
    }
}

/// Current figures and the paths for the scene, from Horizons.
@MainActor
final class SpaceSceneModel: ObservableObject {
    @Published private(set) var sunTrack: HorizonsTrack?
    @Published private(set) var earthTrack: HorizonsTrack?
    @Published private(set) var localTrack: HorizonsTrack?
    @Published private(set) var moonFromEarth: HorizonsTrack?
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false
    @Published private(set) var now = Astro.julianDate()

    func load(_ object: SpaceObject, focus: SpaceFocus) async {
        guard let id = object.horizons else { return }
        isLoading = true
        defer { isLoading = false }
        // One at a time, as JPL asks of scripts.
        let sun = await Horizons.track(object: id, centre: 10)
        let earth = await Horizons.track(object: id, centre: 399)
        var local: HorizonsTrack?
        switch focus {
        case .near(.earth), .earthAndMoon: local = earth
        case .near(let c): local = await Horizons.track(object: id, centre: c.rawValue)
        case .solarSystem: local = nil
        }
        var moon: HorizonsTrack?
        if focus == .near(.earth) || focus == .earthAndMoon || focus == .near(.moon) {
            moon = await Horizons.track(object: 301, centre: 399)
        }
        if Task.isCancelled { return }
        sunTrack = sun
        earthTrack = earth
        localTrack = local
        moonFromEarth = moon
        now = Astro.julianDate()
        failed = sun == nil
    }

    func tick() { now = Astro.julianDate() }

    var distanceFromEarthKm: Double? { earthTrack?.at(now).map { simd_length($0.position) } }
    var distanceFromSunKm: Double? { sunTrack?.at(now).map { simd_length($0.position) } }
    var speedKmS: Double? { sunTrack?.at(now).map { simd_length($0.velocity) } }
}

enum SpaceWords {
    static func distance(_ km: Double) -> String {
        if km >= 0.1 * Horizons.kmPerAU { return String(format: "%.2f AU", km / Horizons.kmPerAU) }
        if km >= 1_000_000 { return String(format: "%.2f million km", km / 1_000_000) }
        return "\(Int(km).formatted()) km"
    }

    /// How long a radio signal takes.
    static func lightTime(_ km: Double) -> String {
        let seconds = km / 299_792.458
        if seconds < 90 { return String(format: "%.1f seconds", seconds) }
        if seconds < 5400 { return String(format: "%.0f minutes", seconds / 60) }
        return String(format: "%.1f hours", seconds / 3600)
    }
}

/// SceneKit's up is Y, and these numbers have the ecliptic's up as Z.
private func scene(_ v: SIMD3<Double>) -> SCNVector3 { SCNVector3(CGFloat(v.x), CGFloat(v.z), CGFloat(-v.y)) }

/// A marker or name that stays the same size on screen however far the camera goes.
final class ConstantSize {
    let node: SCNNode
    let size: CGFloat
    init(node: SCNNode, size: CGFloat) { self.node = node; self.size = size }
}

private func labelNode(_ text: String, colour: NSColor, weight: NSFont.Weight = .medium) -> SCNNode {
    let font = NSFont.systemFont(ofSize: 34, weight: weight)
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
    let size = attributed.size()
    let image = NSImage(size: NSSize(width: ceil(size.width) + 8, height: ceil(size.height) + 4), flipped: false) { _ in
        attributed.draw(at: NSPoint(x: 4, y: 2))
        return true
    }
    let plane = SCNPlane(width: image.size.width / 100, height: image.size.height / 100)
    plane.firstMaterial?.diffuse.contents = image
    plane.firstMaterial?.lightingModel = .constant
    plane.firstMaterial?.isDoubleSided = true
    plane.firstMaterial?.writesToDepthBuffer = false
    let inner = SCNNode(geometry: plane)
    // Sits to the right of the point it names.
    inner.position = SCNVector3(plane.width / 2 + 0.12, 0, 0)
    let holder = SCNNode()
    holder.addChildNode(inner)
    holder.constraints = [SCNBillboardConstraint()]
    holder.renderingOrder = 10
    return holder
}

private func dotNode(_ colour: NSColor) -> SCNNode {
    let sphere = SCNSphere(radius: 1)
    sphere.segmentCount = 16
    sphere.firstMaterial?.diffuse.contents = colour
    sphere.firstMaterial?.lightingModel = .constant
    return SCNNode(geometry: sphere)
}

private func lineNode(_ points: [SCNVector3], colour: NSColor) -> SCNNode? {
    guard points.count >= 2 else { return nil }
    let source = SCNGeometrySource(vertices: points)
    var indices: [Int32] = []
    for i in 0..<(points.count - 1) { indices += [Int32(i), Int32(i + 1)] }
    let element = SCNGeometryElement(indices: indices, primitiveType: .line)
    let geometry = SCNGeometry(sources: [source], elements: [element])
    geometry.firstMaterial?.diffuse.contents = colour
    geometry.firstMaterial?.lightingModel = .constant
    return SCNNode(geometry: geometry)
}

private func texturedSphere(radius: CGFloat, resource: String?, fallback: NSColor) -> SCNNode {
    let sphere = SCNSphere(radius: radius)
    sphere.segmentCount = 96
    let material = sphere.firstMaterial
    if let resource, let url = Res.url(resource), let image = NSImage(contentsOf: url) {
        material?.diffuse.contents = image
    } else {
        material?.diffuse.contents = fallback
    }
    material?.lightingModel = .lambert
    return SCNNode(geometry: sphere)
}

/// Holds the scene, and keeps markers the same size on screen as the camera moves.
final class SpaceRenderer: NSObject, SCNSceneRendererDelegate {
    var sized: [ConstantSize] = []
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let camera = renderer.pointOfView else { return }
        let eye = simd_float3(camera.simdWorldPosition)
        for item in sized {
            let d = simd_distance(eye, item.node.simdWorldPosition)
            let s = CGFloat(d) * item.size
            item.node.scale = SCNVector3(s, s, s)
        }
    }
}

struct SpaceSceneView: NSViewRepresentable {
    let object: SpaceObject
    let focus: SpaceFocus
    @ObservedObject var model: SpaceSceneModel

    final class Coordinator {
        let renderer = SpaceRenderer()
        var builtKey = ""
        var craft: SCNNode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.delegate = context.coordinator.renderer
        view.isPlaying = true
        view.rendersContinuously = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        // Rebuilding would throw away where the viewer moved the camera, so only for new data.
        let key = "\(object.id)|\(focus)|\(model.sunTrack?.points.count ?? 0)|\(model.localTrack?.points.first?.jd ?? 0)|\(model.moonFromEarth?.points.count ?? 0)"
        if key != c.builtKey {
            c.builtKey = key
            let built = build()
            view.scene = built.scene
            view.pointOfView = built.camera
            c.renderer.sized = built.sized
            c.craft = built.craft
        }
        // It moves on between fetches.
        if let craft = c.craft, let p = currentCraftPosition() { craft.position = p }
    }

    private struct Built {
        let scene: SCNScene
        let camera: SCNNode
        let sized: [ConstantSize]
        let craft: SCNNode?
    }

    private var craftColour: NSColor { NSColor(red: 1, green: 0.8, blue: 0.2, alpha: 1) }

    private func currentCraftPosition() -> SCNVector3? {
        switch focus {
        case .solarSystem:
            return model.sunTrack?.at(model.now).map { scene(SolarScale.compressed($0.position / Horizons.kmPerAU)) }
        default:
            return model.localTrack?.at(model.now).map { scene($0.position / 1000) }
        }
    }

    private func build() -> Built {
        focus == .solarSystem ? buildSolarSystem() : buildLocal()
    }

    private func addMarked(_ name: String, at position: SCNVector3, colour: NSColor, dot: CGFloat, to parent: SCNNode, sized: inout [ConstantSize]) -> SCNNode {
        let holder = SCNNode()
        holder.position = position
        let marker = dotNode(colour)
        holder.addChildNode(marker)
        sized.append(ConstantSize(node: marker, size: dot))
        let label = labelNode(name, colour: colour)
        holder.addChildNode(label)
        sized.append(ConstantSize(node: label, size: 0.05))
        parent.addChildNode(holder)
        return holder
    }

    private func camera(at position: SCNVector3, lookingAt target: SCNVector3 = SCNVector3(0, 0, 0)) -> SCNNode {
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 50
        let node = SCNNode()
        node.camera = camera
        node.position = position
        node.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        return node
    }

    private func stars(_ parent: SCNNode, radius: Double) {
        var points: [SCNVector3] = []
        var g = SystemRandomNumberGenerator()
        for _ in 0..<1500 {
            let z = Double.random(in: -1...1, using: &g), a = Double.random(in: 0...(2 * .pi), using: &g)
            let r = sqrt(1 - z * z)
            points.append(SCNVector3(radius * r * cos(a), radius * r * sin(a), radius * z))
        }
        let source = SCNGeometrySource(vertices: points)
        let element = SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .point)
        element.pointSize = 1.5
        element.minimumPointScreenSpaceRadius = 0.5
        element.maximumPointScreenSpaceRadius = 1.5
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.diffuse.contents = NSColor(white: 0.75, alpha: 1)
        geometry.firstMaterial?.lightingModel = .constant
        parent.addChildNode(SCNNode(geometry: geometry))
    }

    private func buildSolarSystem() -> Built {
        let s = SCNScene()
        let root = s.rootNode
        var sized: [ConstantSize] = []
        stars(root, radius: 900)
        let jd = model.now

        let sun = dotNode(NSColor(red: 1, green: 0.85, blue: 0.45, alpha: 1))
        sun.scale = SCNVector3(2.4, 2.4, 2.4)
        root.addChildNode(sun)
        let sunLabel = labelNode("Sun", colour: NSColor(red: 1, green: 0.85, blue: 0.45, alpha: 1))
        sunLabel.position = SCNVector3(2.6, 0, 0)
        root.addChildNode(sunLabel)
        sized.append(ConstantSize(node: sunLabel, size: 0.05))

        let light = SCNLight()
        light.type = .omni
        light.intensity = 1400
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = 0
        let lightNode = SCNNode()
        lightNode.light = light
        root.addChildNode(lightNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 170
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        // Something this close to a planet can't be told apart from it here, so one label says both.
        let craftNow = model.sunTrack?.at(jd).map { SolarScale.compressed($0.position / Horizons.kmPerAU) }
        var craftLabel = object.name
        for planet in Planet.all {
            let beside = craftNow.map { simd_distance($0, SolarScale.compressed(planet.position(jd: jd))) < 1.5 } ?? false
            if beside { craftLabel += ", at \(planet.name)" }
            let ring = stride(from: 0.0, through: 360.0, by: 3).map { scene(SolarScale.compressed(planet.position(jd: jd, shift: $0))) }
            if let line = lineNode(ring, colour: NSColor(white: 0.32, alpha: 1)) { root.addChildNode(line) }
            let colour = NSColor(red: planet.colour.r, green: planet.colour.g, blue: planet.colour.b, alpha: 1)
            let body = SCNSphere(radius: planet.drawRadius)
            body.segmentCount = 32
            body.firstMaterial?.diffuse.contents = colour
            body.firstMaterial?.lightingModel = .lambert
            let node = SCNNode(geometry: body)
            let at = scene(SolarScale.compressed(planet.position(jd: jd)))
            node.position = at
            root.addChildNode(node)
            if !beside {
                let label = labelNode(planet.name, colour: colour.withAlphaComponent(0.9), weight: .regular)
                label.position = SCNVector3(at.x, at.y + planet.drawRadius + 0.2, at.z)
                root.addChildNode(label)
                sized.append(ConstantSize(node: label, size: 0.04))
            }
        }

        var craftNode: SCNNode?
        var farthest = simd_length(SolarScale.compressed(SIMD3(30.1, 0, 0)))
        if let track = model.sunTrack {
            let trail = track.trail(upTo: jd).map { scene(SolarScale.compressed($0 / Horizons.kmPerAU)) }
            if let line = lineNode(trail, colour: craftColour.withAlphaComponent(0.7)) { root.addChildNode(line) }
            if let now = track.at(jd) {
                let au = now.position / Horizons.kmPerAU
                let p = SolarScale.compressed(au)
                farthest = max(farthest, simd_length(p))
                craftNode = addMarked(craftLabel, at: scene(p), colour: craftColour, dot: 0.0055, to: root, sized: &sized)
            }
        }
        let d = farthest * 1.5
        // Close enough to the craft to be worth looking at when it's in the inner solar system.
        let cam = camera(at: SCNVector3(d * 0.25, d * 0.85, d * 0.75))
        root.addChildNode(cam)
        return Built(scene: s, camera: cam, sized: sized, craft: craftNode)
    }

    /// Real distances, in thousands of km, around one body.
    private func buildLocal() -> Built {
        let s = SCNScene()
        let root = s.rootNode
        var sized: [ConstantSize] = []
        let jd = model.now
        let centre: SpaceObject.Centre
        switch focus {
        case .near(let c): centre = c
        default: centre = .earth
        }
        let radius = centre.radiusKm / 1000

        let moonNow = model.moonFromEarth?.at(jd)?.position
        let texture: String? = centre == .earth ? "earth_day.jpg" : centre == .moon ? "moon.jpg" : nil
        let tint = centre == .mars ? NSColor(red: 0.8, green: 0.42, blue: 0.26, alpha: 1)
            : centre == .jupiter ? NSColor(red: 0.85, green: 0.72, blue: 0.55, alpha: 1) : NSColor.gray
        let body = texturedSphere(radius: radius, resource: texture, fallback: tint)
        root.addChildNode(body)
        sized.append(ConstantSize(node: { let l = labelNode(centre.name, colour: .white); l.position = SCNVector3(radius * 1.02, radius * 0.9, 0); root.addChildNode(l); return l }(), size: 0.05))

        // The Sun's direction, for true day and night.
        let earth = Planet.all[2].position(jd: jd)
        let sunward: SIMD3<Double>
        switch centre {
        case .mars: sunward = -Planet.all[3].position(jd: jd)
        case .jupiter: sunward = -Planet.all[4].position(jd: jd)
        default: sunward = -earth
        }
        let sunNode = SCNNode()
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1300
        sunNode.light = sunLight
        sunNode.position = scene(simd_normalize(sunward) * 1000)
        sunNode.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        root.addChildNode(sunNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 60
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)
        stars(root, radius: 900_000)

        // The Earth and Moon in their true places, so each is seen from the other.
        var earthAsSeen: SIMD3<Double>?
        if centre == .earth, let track = model.moonFromEarth {
            let path = track.points.map { scene($0.position / 1000) }
            if let line = lineNode(path, colour: NSColor(white: 0.4, alpha: 1)) { root.addChildNode(line) }
            if let now = moonNow {
                let moon = texturedSphere(radius: 1.737, resource: "moon.jpg", fallback: .gray)
                moon.position = scene(now / 1000)
                root.addChildNode(moon)
                if focus != .earthAndMoon {
                    _ = addMarked("Moon", at: scene(now / 1000), colour: NSColor(white: 0.85, alpha: 1), dot: 0.003, to: root, sized: &sized)
                }
            }
        }
        if centre == .moon, let now = moonNow {
            let there = -now / 1000
            earthAsSeen = there
            let earthNode = texturedSphere(radius: 6.371, resource: "earth_day.jpg", fallback: .blue)
            earthNode.position = scene(there)
            root.addChildNode(earthNode)
            _ = addMarked("Earth", at: scene(there), colour: NSColor(red: 0.5, green: 0.7, blue: 1, alpha: 1), dot: 0.0, to: root, sized: &sized)
            // The Moon keeps one face to the Earth.
            body.look(at: scene(there), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, 1))
        }

        var craftNode: SCNNode?
        var reach = radius * 3
        if let track = model.localTrack {
            // From this far back, weeks of low lunar orbits are only a scribble around the Moon's own path.
            if focus != .earthAndMoon, let line = lineNode(track.trail(upTo: jd).map { scene($0 / 1000) }, colour: craftColour.withAlphaComponent(0.8)) {
                root.addChildNode(line)
            }
            if let now = track.at(jd) {
                let p = now.position / 1000
                reach = max(reach, simd_length(p))
                craftNode = addMarked(focus == .earthAndMoon ? "\(object.name), at the Moon" : object.name, at: scene(p), colour: craftColour, dot: 0.0055, to: root, sized: &sized)
            }
        }

        let cam: SCNNode
        if focus == .earthAndMoon {
            cam = camera(at: SCNVector3(300, 700, 500))
        } else if let earthAsSeen {
            // From behind the Moon, so the Earth hangs in the same view as the orbit.
            let back = -simd_normalize(earthAsSeen) * radius * 3.2 + SIMD3(0, 0, radius * 1.2)
            cam = camera(at: scene(back))
        } else {
            let d = max(reach * 1.9, radius * 4)
            cam = camera(at: SCNVector3(d * 0.5, d * 0.55, d * 0.7))
        }
        root.addChildNode(cam)
        return Built(scene: s, camera: cam, sized: sized, craft: craftNode)
    }
}

/// Fills the globe's frame while a spacecraft out of the globe's reach is selected.
struct SpaceSceneOverlay: View {
    let object: SpaceObject
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SatelliteStore
    @StateObject private var model = SpaceSceneModel()
    @State private var focus: SpaceFocus = .solarSystem

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    var body: some View {
        ZStack {
            SpaceSceneView(object: object, focus: focus, model: model)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) { card.padding(12) }
        .overlay(alignment: .topTrailing) {
            Button { app.closeSpaceObject() } label: {
                Label("Back to Earth", systemImage: "globe.americas.fill")
            }
            .controlSize(.large)
            .padding(12)
        }
        .overlay(alignment: .bottom) { controls.padding(12) }
        .overlay {
            if model.failed, !model.isLoading {
                Label("Couldn't get this spacecraft's position from NASA JPL", systemImage: "exclamationmark.triangle")
                    .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if model.isLoading, model.sunTrack == nil {
                ProgressView("Getting its position from NASA JPL…")
                    .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: "\(object.id)|\(focus)") {
            await model.load(object, focus: focus)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                model.tick()
                // Fetches again only once what it has has run its time.
                if let last = (focus == .solarSystem ? model.sunTrack : model.localTrack)?.points.last?.jd, model.now > last - 1.0 / 48 {
                    await model.load(object, focus: focus)
                }
            }
        }
        .onChange(of: object) { _, new in focus = new.focuses[0] }
        .onAppear {
            focus = object.focuses[0]
            if let i = Snapshot.arguments.firstIndex(of: "--space-focus"), let n = Int(Snapshot.arguments[i + 1]), n < object.focuses.count { focus = object.focuses[n] }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(object.name).font(.system(size: 15, weight: .semibold))
            Text(object.about).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if let km = model.distanceFromEarthKm {
                line("From Earth", SpaceWords.distance(km))
                line("Signal takes", SpaceWords.lightTime(km))
            }
            if let km = model.distanceFromSunKm { line("From the Sun", SpaceWords.distance(km)) }
            if let v = model.speedKmS { line("Speed", String(format: "%.1f km/s around the Sun", v)) }
            line("Launched", String(object.launched))
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if object.focuses.count > 1 {
                    Picker("", selection: $focus) {
                        ForEach(object.focuses, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                Menu("Other spacecraft") {
                    ForEach(SpaceObject.Kind.allCases) { kind in
                        Section(kind.rawValue) {
                            ForEach(SpaceCatalog.of(kind: kind)) { o in
                                Button(o.name) { app.openSpaceObject(o, store: store) }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            Text(focus == .solarSystem
                 ? "Directions are true. Distances are squeezed and planets enlarged so everything fits. Positions: NASA JPL Horizons, planets from JPL elements."
                 : "True scale, drag to look around. Positions: NASA JPL Horizons. Moon image: NASA/GSFC.")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.65)).shadow(color: .black, radius: 2)
        }
    }
}
