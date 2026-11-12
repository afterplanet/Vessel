import SwiftUI
import SceneKit

/// Interactive preview: drag to rotate and tilt, scroll to zoom. Turns slowly on its own.
struct SatelliteModelView: NSViewRepresentable {
    let satellite: Satellite
    /// The real model once it has arrived.
    let model: SCNNode?

    final class Coordinator {
        var shownKind: SatelliteModel.Kind?
        weak var shownModel: SCNNode?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 30
        v.scene = SCNScene()
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.maximumVerticalAngle = 85
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let kind = SatelliteModel.kind(for: satellite)
        let c = context.coordinator
        guard kind != c.shownKind || model !== c.shownModel else { return }
        c.shownKind = kind
        c.shownModel = model
        v.scene = model.map { SatelliteModel.scene(showing: $0) } ?? SatelliteModel.scene(kind)
        v.pointOfView = v.scene?.rootNode.childNode(withName: "camera", recursively: false)
    }
}

/// Representative models. No public catalogue has real 3D geometry for every object in orbit,
/// so each satellite maps to the bus shape typical of its class.
enum SatelliteModel {
    enum Kind: String { case station, comsat, flatPanel, weather, navigation, cubesat, observatory, recon, generic
        var caption: String {
            switch self {
            case .station: "Modular space station"
            case .comsat: "Geostationary comsat bus"
            case .flatPanel: "Flat-panel constellation bus"
            case .weather: "Polar weather platform"
            case .navigation: "Navigation satellite"
            case .cubesat: "CubeSat"
            case .observatory: "Space observatory"
            case .recon: "Reconnaissance bus"
            case .generic: "Generic smallsat bus"
            }
        }
    }

    static func kind(for s: Satellite) -> Kind {
        let n = s.name.uppercased()
        if s.category == .station { return .station }
        if n.hasPrefix("STARLINK") || n.hasPrefix("ONEWEB") || n.hasPrefix("KUIPER") || n.hasPrefix("QIANFAN") { return .flatPanel }
        if ["HST", "HUBBLE", "CXO", "CHANDRA", "XMM", "JWST", "SWIFT", "FERMI", "IXPE", "NUSTAR"].contains(where: { n.hasPrefix($0) }) { return .observatory }
        switch s.category {
        case .weather: return .weather
        case .navigation: return .navigation
        case .military: return .recon
        case .communications: return s.orbit == .leo || s.orbit == .sso ? .flatPanel : .comsat
        case .education, .amateur: return .cubesat
        case .earthObservation, .research: return .weather
        default: return s.orbit == .leo || s.orbit == .sso ? .generic : .comsat
        }
    }

    private static func mat(_ c: NSColor, metal: CGFloat = 0.8, rough: CGFloat = 0.4) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }
    private static let foil = mat(NSColor(red: 0.85, green: 0.62, blue: 0.2, alpha: 1), metal: 0.95, rough: 0.35)
    private static let silver = mat(NSColor(white: 0.78, alpha: 1), metal: 0.9, rough: 0.3)
    private static let white = mat(NSColor(white: 0.9, alpha: 1), metal: 0.1, rough: 0.6)
    private static let dark = mat(NSColor(white: 0.12, alpha: 1), metal: 0.6, rough: 0.5)

    private static let solar: SCNMaterial = {
        let size = 128
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(red: 0.04, green: 0.08, blue: 0.3, alpha: 1).setFill(); rect.fill()
            NSColor(red: 0.45, green: 0.55, blue: 0.75, alpha: 1).setStroke()
            let p = NSBezierPath(); p.lineWidth = 1.5
            for i in stride(from: 0, through: size, by: 32) {
                p.move(to: NSPoint(x: i, y: 0)); p.line(to: NSPoint(x: i, y: size))
                p.move(to: NSPoint(x: 0, y: i)); p.line(to: NSPoint(x: size, y: i))
            }
            p.stroke()
            return true
        }
        let m = mat(.white, metal: 0.75, rough: 0.28)
        m.diffuse.contents = img
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        return m
    }()

    private static func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, at p: SCNVector3 = SCNVector3(0, 0, 0)) -> SCNNode {
        let g = SCNBox(width: w, height: h, length: l, chamferRadius: min(w, h, l) * 0.04)
        g.materials = [m]
        let n = SCNNode(geometry: g); n.position = p
        return n
    }

    private static func cyl(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial, at p: SCNVector3 = SCNVector3(0, 0, 0), axis: Character = "y") -> SCNNode {
        let g = SCNCylinder(radius: r, height: h)
        g.materials = [m]
        let n = SCNNode(geometry: g); n.position = p
        if axis == "x" { n.eulerAngles.z = .pi / 2 }
        if axis == "z" { n.eulerAngles.x = .pi / 2 }
        return n
    }

    private static func panel(_ w: CGFloat, _ l: CGFloat, at p: SCNVector3, cells: CGFloat = 4) -> SCNNode {
        let g = SCNBox(width: w, height: 0.012, length: l, chamferRadius: 0)
        let m = solar.copy() as! SCNMaterial
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(w * cells, l * cells, 1)
        let edge = dark
        g.materials = [edge, edge, edge, edge, m, m]
        // A box's top and bottom faces are its last two materials.
        let n = SCNNode(geometry: g); n.position = p
        return n
    }

    private static func dish(_ r: CGFloat, at p: SCNVector3, facing x: CGFloat = 0) -> SCNNode {
        let g = SCNSphere(radius: r)
        g.isGeodesic = false
        g.materials = [white]
        let n = SCNNode(geometry: g)
        n.scale = SCNVector3(1, 0.22, 1)
        n.position = p
        n.eulerAngles.z = x
        return n
    }

    private static func build(_ kind: Kind) -> SCNNode {
        let root = SCNNode()
        func add(_ n: SCNNode) { root.addChildNode(n) }
        switch kind {
        case .station:
            add(box(4.6, 0.08, 0.08, silver))
            for x: CGFloat in [-2.2, -1.5, 1.5, 2.2] {
                add(panel(0.42, 2.4, at: SCNVector3(x, 0, 1.28), cells: 6))
                add(panel(0.42, 2.4, at: SCNVector3(x, 0, -1.28), cells: 6))
            }
            add(cyl(0.17, 1.6, white, at: SCNVector3(0, 0, 0), axis: "z"))
            add(cyl(0.15, 1.0, silver, at: SCNVector3(0, 0, 1.25), axis: "z"))
            add(cyl(0.15, 1.1, white, at: SCNVector3(0, 0, -1.3), axis: "z"))
            add(cyl(0.16, 0.8, white, at: SCNVector3(0.55, 0, -0.4), axis: "x"))
            add(cyl(0.16, 0.8, white, at: SCNVector3(-0.55, 0, -0.4), axis: "x"))
            add(box(0.7, 0.02, 0.3, white, at: SCNVector3(0.7, 0.28, 0)))
        case .comsat:
            add(box(0.9, 0.9, 1.1, foil))
            add(panel(2.2, 0.75, at: SCNVector3(1.6, 0, 0)))
            add(panel(2.2, 0.75, at: SCNVector3(-1.6, 0, 0)))
            add(box(0.26, 0.04, 0.04, silver, at: SCNVector3(0.5, 0, 0)))
            add(box(0.26, 0.04, 0.04, silver, at: SCNVector3(-0.5, 0, 0)))
            add(dish(0.45, at: SCNVector3(0.0, 0.75, 0.35)))
            add(dish(0.32, at: SCNVector3(0.0, 0.62, -0.42)))
            add(cyl(0.12, 0.3, dark, at: SCNVector3(0, -0.6, 0)))
        case .flatPanel:
            add(box(1.5, 0.12, 0.8, silver))
            add(panel(2.9, 0.75, at: SCNVector3(2.3, 0.05, 0), cells: 3))
            for (x, z) in [(-0.45, -0.2), (0.0, -0.2), (0.45, -0.2), (-0.45, 0.2), (0.0, 0.2), (0.45, 0.2)] as [(CGFloat, CGFloat)] {
                add(box(0.26, 0.04, 0.26, white, at: SCNVector3(x, -0.08, z)))
            }
        case .weather:
            add(box(0.7, 0.7, 1.9, silver))
            add(box(0.72, 0.5, 0.4, foil, at: SCNVector3(0, 0, -0.7)))
            add(panel(0.9, 2.5, at: SCNVector3(0, 0.55, -1.9), cells: 3))
            add(cyl(0.2, 0.32, white, at: SCNVector3(0, -0.5, 0.55)))
            add(cyl(0.16, 0.24, dark, at: SCNVector3(0.22, -0.46, 0.05)))
            add(cyl(0.02, 1.1, silver, at: SCNVector3(-0.75, 0, 0.5), axis: "x"))
            add(dish(0.16, at: SCNVector3(-1.3, 0, 0.5), facing: .pi / 2))
        case .navigation:
            add(box(0.8, 0.8, 0.8, foil))
            add(panel(1.9, 0.75, at: SCNVector3(1.4, 0, 0)))
            add(panel(1.9, 0.75, at: SCNVector3(-1.4, 0, 0)))
            add(box(0.7, 0.14, 0.7, white, at: SCNVector3(0, 0.46, 0)))
            for (x, z) in [(-0.2, -0.2), (0.2, -0.2), (-0.2, 0.2), (0.2, 0.2), (0, 0)] as [(CGFloat, CGFloat)] {
                add(cyl(0.07, 0.2, silver, at: SCNVector3(x, 0.62, z)))
            }
        case .cubesat:
            add(box(0.7, 0.7, 1.4, dark))
            add(box(0.72, 0.72, 0.02, silver, at: SCNVector3(0, 0, 0.35)))
            add(box(0.72, 0.72, 0.02, silver, at: SCNVector3(0, 0, -0.35)))
            add(panel(0.68, 1.3, at: SCNVector3(0.72, 0.1, 0), cells: 3))
            add(panel(0.68, 1.3, at: SCNVector3(-0.72, 0.1, 0), cells: 3))
            for (x, y) in [(0.33, 0.33), (-0.33, 0.33), (0.33, -0.33), (-0.33, -0.33)] as [(CGFloat, CGFloat)] {
                add(cyl(0.008, 1.4, silver, at: SCNVector3(x, y, 1.3), axis: "z"))
            }
        case .observatory:
            add(cyl(0.55, 2.8, silver, at: SCNVector3(0, 0, 0), axis: "z"))
            add(cyl(0.6, 0.6, foil, at: SCNVector3(0, 0, -1.2), axis: "z"))
            add(cyl(0.56, 0.05, dark, at: SCNVector3(0, 0, 1.42), axis: "z"))
            add(panel(0.8, 2.6, at: SCNVector3(1.2, 0, -0.3), cells: 3))
            add(panel(0.8, 2.6, at: SCNVector3(-1.2, 0, -0.3), cells: 3))
            add(dish(0.22, at: SCNVector3(0, 0.75, -0.8)))
        case .recon:
            add(cyl(0.55, 2.6, dark, at: SCNVector3(0, 0, 0), axis: "z"))
            add(cyl(0.58, 0.8, foil, at: SCNVector3(0, 0, -1.0), axis: "z"))
            add(panel(2.0, 0.8, at: SCNVector3(1.7, 0, -1.0)))
            add(panel(2.0, 0.8, at: SCNVector3(-1.7, 0, -1.0)))
            add(dish(0.25, at: SCNVector3(0, 0.75, -0.4)))
        case .generic:
            add(box(0.85, 0.85, 0.85, foil))
            add(panel(1.3, 0.75, at: SCNVector3(1.08, 0, 0)))
            add(panel(1.3, 0.75, at: SCNVector3(-1.08, 0, 0)))
            add(cyl(0.05, 0.5, silver, at: SCNVector3(0, 0.65, 0)))
            add(dish(0.22, at: SCNVector3(0, 0.95, 0)))
        }
        return root
    }

    static func scene(_ kind: Kind) -> SCNScene { scene(showing: build(kind)) }

    /// What metal surfaces reflect: black space above, with the bright Earth below and the Sun to
    /// one side. Without something to reflect, foil and solar cells render flat and dark.
    private static let reflections: NSImage = {
        NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.55, green: 0.66, blue: 0.82, alpha: 1), NSColor(red: 0.2, green: 0.26, blue: 0.36, alpha: 1),
                                NSColor(white: 0.03, alpha: 1), NSColor(white: 0.01, alpha: 1)],
                       atLocations: [0, 0.38, 0.55, 1], colorSpace: .deviceRGB)?.draw(in: rect, angle: 90)
            NSGradient(colors: [.white, NSColor(white: 1, alpha: 0)])?
                .draw(in: NSBezierPath(ovalIn: NSRect(x: 120, y: 150, width: 90, height: 90)), relativeCenterPosition: .zero)
            return true
        }
    }()

    static func scene(showing model: SCNNode) -> SCNScene {
        let s = SCNScene()
        s.background.contents = NSColor.clear
        s.lightingEnvironment.contents = reflections
        s.lightingEnvironment.intensity = 1.4

        // The preview is wide, so the long axis lies across it, and the model turns around that
        // axis. That way it fills the frame, and flat solar arrays never stay edge-on.
        let (lo, hi) = model.boundingBox
        let size = SCNVector3(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let centre = SCNVector3((hi.x + lo.x) / 2, (hi.y + lo.y) / 2, (hi.z + lo.z) / 2)
        let longest = max(size.x, max(size.y, size.z))
        let lying = SCNNode()
        lying.addChildNode(model)
        model.position = SCNVector3(-centre.x, -centre.y, -centre.z)
        var across = (size.y, size.z)
        if longest == size.y, longest != size.x {
            lying.eulerAngles.z = -.pi / 2
            across = (size.x, size.z)
        } else if longest == size.z, longest != size.x {
            lying.eulerAngles.y = .pi / 2
            across = (size.y, size.x)
        }
        // Turning sweeps the short axes through their diagonal, which mustn't clip the frame.
        let sweep = (across.0 * across.0 + across.1 * across.1).squareRoot()
        let k = min(6.4 / max(longest, 0.001), 3.3 / max(sweep, 0.001))
        lying.scale = SCNVector3(k, k, k)

        let spin = SCNNode()
        spin.addChildNode(lying)
        spin.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: 0, duration: 40)))
        let view = SCNNode()
        view.eulerAngles = SCNVector3(0.18, -0.32, 0)
        view.addChildNode(spin)
        s.rootNode.addChildNode(view)

        // Enough everywhere that the side away from the Sun still shows its detail.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 320
        ambient.light?.color = NSColor(red: 0.82, green: 0.87, blue: 1, alpha: 1)
        s.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1700
        sun.light?.color = NSColor(white: 1, alpha: 1)
        sun.eulerAngles = SCNVector3(-0.7, 0.8, 0)
        s.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 280
        fill.light?.color = NSColor(red: 0.55, green: 0.7, blue: 1, alpha: 1)
        fill.eulerAngles = SCNVector3(0.5, -2.4, 0)
        s.rootNode.addChildNode(fill)

        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 30
        cam.camera?.wantsHDR = false
        cam.position = SCNVector3(0, 0, 7.4)
        s.rootNode.addChildNode(cam)
        return s
    }
}
