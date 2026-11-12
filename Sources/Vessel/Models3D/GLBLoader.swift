import SceneKit
import AppKit
import CDraco

/// Reads binary glTF into SceneKit, which can't open it directly. Written for NASA's models:
/// Draco-compressed meshes, PBR materials, and embedded PNG, JPEG or WebP textures.
/// These are downloaded files, so every offset is checked before it's used.
enum GLBLoader {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func load(_ data: Data) throws -> SCNNode {
        let (json, bin) = try chunks(data)
        return try Reader(json: json, bin: bin).root()
    }

    private static func chunks(_ d: Data) throws -> ([String: Any], Data) {
        let bytes = [UInt8](d)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        guard bytes.count >= 20, bytes[0...3].elementsEqual(Array("glTF".utf8)), u32(4) == 2 else { throw Failure("Not a glTF 2 binary") }
        var at = 12
        var json: [String: Any]?
        var bin = Data()
        while at + 8 <= bytes.count {
            let length = u32(at), kind = u32(at + 4)
            let start = at + 8
            guard length >= 0, start + length <= bytes.count else { throw Failure("Truncated chunk") }
            if kind == 0x4E4F534A {
                json = try JSONSerialization.jsonObject(with: d.subdata(in: start..<start + length)) as? [String: Any]
            } else if kind == 0x004E4942 {
                bin = d.subdata(in: start..<start + length)
            }
            at = start + length
        }
        guard let json else { throw Failure("No scene description") }
        return (json, bin)
    }

    private final class Reader {
        let json: [String: Any]
        let bin: Data
        let accessors, views, materials, textures, images, meshes, nodes: [[String: Any]]
        private var imageCache: [Int: NSImage] = [:]
        private var materialCache: [Int: SCNMaterial] = [:]

        init(json: [String: Any], bin: Data) {
            self.json = json
            self.bin = bin
            func list(_ k: String) -> [[String: Any]] { json[k] as? [[String: Any]] ?? [] }
            accessors = list("accessors"); views = list("bufferViews"); materials = list("materials")
            textures = list("textures"); images = list("images"); meshes = list("meshes"); nodes = list("nodes")
        }

        func root() throws -> SCNNode {
            let scenes = json["scenes"] as? [[String: Any]] ?? []
            let which = json["scene"] as? Int ?? 0
            let tops = (scenes.indices.contains(which) ? scenes[which]["nodes"] as? [Int] : nil) ?? Array(nodes.indices)
            let top = SCNNode()
            var visited = Set<Int>()
            for n in tops { if let child = try node(n, &visited) { top.addChildNode(child) } }
            return top
        }

        private func node(_ index: Int, _ visited: inout Set<Int>) throws -> SCNNode? {
            // Malformed files could otherwise loop forever.
            guard nodes.indices.contains(index), visited.insert(index).inserted else { return nil }
            let n = nodes[index]
            let out = SCNNode()
            out.name = n["name"] as? String
            if let m = (n["matrix"] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), m.count == 16 {
                out.transform = SCNMatrix4(m11: m[0], m12: m[1], m13: m[2], m14: m[3], m21: m[4], m22: m[5], m23: m[6], m24: m[7],
                                           m31: m[8], m32: m[9], m33: m[10], m34: m[11], m41: m[12], m42: m[13], m43: m[14], m44: m[15])
            } else {
                func v(_ k: String) -> [CGFloat]? { (n[k] as? [NSNumber])?.map { CGFloat($0.doubleValue) } }
                if let t = v("translation"), t.count == 3 { out.position = SCNVector3(t[0], t[1], t[2]) }
                if let r = v("rotation"), r.count == 4 { out.orientation = SCNQuaternion(r[0], r[1], r[2], r[3]) }
                if let s = v("scale"), s.count == 3 { out.scale = SCNVector3(s[0], s[1], s[2]) }
            }
            if let m = n["mesh"] as? Int, meshes.indices.contains(m) {
                for p in meshes[m]["primitives"] as? [[String: Any]] ?? [] {
                    if let g = try primitive(p) { out.addChildNode(SCNNode(geometry: g)) }
                }
            }
            for c in n["children"] as? [Int] ?? [] {
                if let child = try node(c, &visited) { out.addChildNode(child) }
            }
            return out
        }

        private func view(_ index: Int) -> Data? {
            guard views.indices.contains(index) else { return nil }
            let v = views[index]
            let offset = v["byteOffset"] as? Int ?? 0, length = v["byteLength"] as? Int ?? 0
            guard offset >= 0, length > 0, offset + length <= bin.count else { return nil }
            return bin.subdata(in: bin.startIndex + offset..<bin.startIndex + offset + length)
        }

        private func primitive(_ p: [String: Any]) throws -> SCNGeometry? {
            guard (p["mode"] as? Int ?? 4) == 4, let attrs = p["attributes"] as? [String: Int] else { return nil }
            var positions: [Float], normals: [Float]?, uvs: [Float]?, indices: [UInt32]
            let ext = p["extensions"] as? [String: Any]
            if let draco = ext?["KHR_draco_mesh_compression"] as? [String: Any] {
                guard let bv = draco["bufferView"] as? Int, let ids = draco["attributes"] as? [String: Int], let raw = view(bv),
                      let mesh = raw.withUnsafeBytes({ cdraco_decode($0.bindMemory(to: UInt8.self).baseAddress, raw.count) }) else {
                    throw Failure("Couldn't decode a compressed mesh")
                }
                defer { cdraco_free(mesh) }
                let count = Int(cdraco_vertex_count(mesh)), faces = Int(cdraco_face_count(mesh))
                func attribute(_ name: String, _ comps: Int) -> [Float]? {
                    guard let id = ids[name] else { return nil }
                    var a = [Float](repeating: 0, count: count * comps)
                    return cdraco_attribute(mesh, UInt32(id), Int32(comps), &a) == 1 ? a : nil
                }
                guard let pos = attribute("POSITION", 3) else { return nil }
                positions = pos
                normals = attribute("NORMAL", 3)
                uvs = attribute("TEXCOORD_0", 2)
                indices = [UInt32](repeating: 0, count: faces * 3)
                cdraco_indices(mesh, &indices)
            } else {
                guard let a = attrs["POSITION"], let pos = floats(a, 3) else { return nil }
                positions = pos
                normals = attrs["NORMAL"].flatMap { floats($0, 3) }
                uvs = attrs["TEXCOORD_0"].flatMap { floats($0, 2) }
                let count = pos.count / 3
                if let i = p["indices"] as? Int {
                    guard let list = indexList(i) else { return nil }
                    indices = list
                } else {
                    indices = (0..<UInt32(count)).map { $0 }
                }
            }
            let vertexCount = positions.count / 3
            guard vertexCount > 0, indices.count >= 3, indices.allSatisfy({ Int($0) < vertexCount }) else { return nil }
            let n = normals ?? Self.flatNormals(positions, indices)

            func source(_ a: [Float], _ s: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
                SCNGeometrySource(data: a.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: s, vectorCount: a.count / comps,
                                  usesFloatComponents: true, componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: comps * 4)
            }
            var sources = [source(positions, .vertex, 3), source(n, .normal, 3)]
            if let uvs { sources.append(source(uvs, .texcoord, 2)) }
            let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                             primitiveCount: indices.count / 3, bytesPerIndex: 4)
            let g = SCNGeometry(sources: sources, elements: [element])
            g.materials = [(p["material"] as? Int).flatMap(material) ?? Self.plainMaterial]
            return g
        }

        private static let plainMaterial: SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(white: 0.75, alpha: 1)
            m.metalness.contents = 0.3
            m.roughness.contents = 0.55
            m.isDoubleSided = true
            return m
        }()

        private static func flatNormals(_ p: [Float], _ idx: [UInt32]) -> [Float] {
            var n = [Float](repeating: 0, count: p.count)
            var i = 0
            while i + 2 < idx.count {
                let a = Int(idx[i]) * 3, b = Int(idx[i + 1]) * 3, c = Int(idx[i + 2]) * 3
                let ux = p[b] - p[a], uy = p[b + 1] - p[a + 1], uz = p[b + 2] - p[a + 2]
                let vx = p[c] - p[a], vy = p[c + 1] - p[a + 1], vz = p[c + 2] - p[a + 2]
                let x = uy * vz - uz * vy, y = uz * vx - ux * vz, z = ux * vy - uy * vx
                for k in [a, b, c] { n[k] += x; n[k + 1] += y; n[k + 2] += z }
                i += 3
            }
            var k = 0
            while k + 2 < n.count {
                let len = (n[k] * n[k] + n[k + 1] * n[k + 1] + n[k + 2] * n[k + 2]).squareRoot()
                if len > 0 { n[k] /= len; n[k + 1] /= len; n[k + 2] /= len }
                k += 3
            }
            return n
        }

        private func layout(_ index: Int) -> (data: Data, offset: Int, count: Int, stride: Int, type: Int, normalized: Bool)? {
            guard accessors.indices.contains(index) else { return nil }
            let a = accessors[index]
            guard let bv = a["bufferView"] as? Int, let data = view(bv), let count = a["count"] as? Int, count > 0,
                  let type = a["componentType"] as? Int else { return nil }
            let stride = views[bv]["byteStride"] as? Int ?? 0
            return (data, a["byteOffset"] as? Int ?? 0, count, stride, type, a["normalized"] as? Bool ?? false)
        }

        private func floats(_ index: Int, _ comps: Int) -> [Float]? {
            guard let l = layout(index) else { return nil }
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5126: 4][l.type] ?? 0
            guard size > 0 else { return nil }
            let stride = l.stride > 0 ? l.stride : size * comps
            guard l.offset >= 0, l.offset + stride * (l.count - 1) + size * comps <= l.data.count else { return nil }
            var out = [Float](repeating: 0, count: l.count * comps)
            l.data.withUnsafeBytes { raw in
                for i in 0..<l.count {
                    for c in 0..<comps {
                        let at = l.offset + i * stride + c * size
                        switch l.type {
                        case 5126: out[i * comps + c] = raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                        case 5123: out[i * comps + c] = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)) / 65535
                        case 5121: out[i * comps + c] = Float(raw[at]) / 255
                        case 5122: out[i * comps + c] = max(Float(raw.loadUnaligned(fromByteOffset: at, as: Int16.self)) / 32767, -1)
                        default: out[i * comps + c] = max(Float(Int8(bitPattern: raw[at])) / 127, -1)
                        }
                    }
                }
            }
            return out
        }

        private func indexList(_ index: Int) -> [UInt32]? {
            guard let l = layout(index) else { return nil }
            let size = [5121: 1, 5123: 2, 5125: 4][l.type] ?? 0
            guard size > 0, l.offset >= 0, l.offset + size * l.count <= l.data.count else { return nil }
            return l.data.withUnsafeBytes { raw in
                (0..<l.count).map { i in
                    let at = l.offset + i * size
                    switch size {
                    case 1: return UInt32(raw[at])
                    case 2: return UInt32(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self))
                    default: return raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)
                    }
                }
            }
        }

        private func image(forTexture t: [String: Any]) -> NSImage? {
            let webp = ((t["extensions"] as? [String: Any])?["EXT_texture_webp"] as? [String: Any])?["source"] as? Int
            for index in [t["source"] as? Int, webp].compactMap({ $0 }) {
                if let hit = imageCache[index] { return hit }
                guard images.indices.contains(index), let bv = images[index]["bufferView"] as? Int, let d = view(bv),
                      let img = NSImage(data: d) else { continue }
                imageCache[index] = img
                return img
            }
            return nil
        }

        private func apply(_ info: [String: Any]?, to property: SCNMaterialProperty) -> Bool {
            guard let info, let i = info["index"] as? Int, textures.indices.contains(i), let img = image(forTexture: textures[i]) else { return false }
            property.contents = img
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.mipFilter = .linear
            property.maxAnisotropy = 8
            if let tr = (info["extensions"] as? [String: Any])?["KHR_texture_transform"] as? [String: Any] {
                let off = (tr["offset"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0]
                let scale = (tr["scale"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1]
                let angle = (tr["rotation"] as? NSNumber)?.doubleValue ?? 0
                var m = SCNMatrix4MakeScale(CGFloat(scale.first ?? 1), CGFloat(scale.last ?? 1), 1)
                if angle != 0 { m = SCNMatrix4Rotate(m, CGFloat(-angle), 0, 0, 1) }
                property.contentsTransform = SCNMatrix4Translate(m, CGFloat(off.first ?? 0), CGFloat(off.last ?? 0), 0)
            }
            return true
        }

        /// glTF's colour factors are linear, so they're given to SceneKit as linear.
        private static func linear(_ c: [Double]) -> NSColor {
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            let comps = [CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2]), CGFloat(c.count > 3 ? c[3] : 1)]
            return CGColor(colorSpace: space, components: comps).flatMap { NSColor(cgColor: $0) } ?? .gray
        }

        private func material(_ index: Int) -> SCNMaterial? {
            if let hit = materialCache[index] { return hit }
            guard materials.indices.contains(index) else { return nil }
            let d = materials[index]
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.name = d["name"] as? String
            m.isDoubleSided = true // Many of these meshes are thin shells seen from both sides.
            let pbr = d["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            let base = (pbr["baseColorFactor"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1, 1, 1]
            // Some of NASA's files use a normal map as the colour too, which renders bright purple.
            func source(_ info: Any?) -> Int? {
                guard let i = (info as? [String: Any])?["index"] as? Int, textures.indices.contains(i) else { return nil }
                return textures[i]["source"] as? Int
            }
            let colorIsNormalMap = source(pbr["baseColorTexture"]) != nil && source(pbr["baseColorTexture"]) == source(d["normalTexture"])
            if !colorIsNormalMap, apply(pbr["baseColorTexture"] as? [String: Any], to: m.diffuse) {
                if base.prefix(3) != [1, 1, 1] { m.multiply.contents = Self.linear(base) }
            } else {
                m.diffuse.contents = Self.linear(base)
            }
            let metal = (pbr["metallicFactor"] as? NSNumber)?.doubleValue ?? 1
            let rough = (pbr["roughnessFactor"] as? NSNumber)?.doubleValue ?? 1
            if apply(pbr["metallicRoughnessTexture"] as? [String: Any], to: m.roughness) {
                m.roughness.textureComponents = .green
                _ = apply(pbr["metallicRoughnessTexture"] as? [String: Any], to: m.metalness)
                m.metalness.textureComponents = .blue
            } else {
                m.metalness.contents = metal
                m.roughness.contents = rough
            }
            _ = apply(d["normalTexture"] as? [String: Any], to: m.normal)
            if apply(d["occlusionTexture"] as? [String: Any], to: m.ambientOcclusion) { m.ambientOcclusion.textureComponents = .red }
            if !apply(d["emissiveTexture"] as? [String: Any], to: m.emission),
               let e = (d["emissiveFactor"] as? [NSNumber])?.map(\.doubleValue), e.contains(where: { $0 > 0 }) {
                m.emission.contents = Self.linear(e)
            }
            let transmission = (((d["extensions"] as? [String: Any])?["KHR_materials_transmission"] as? [String: Any])?["transmissionFactor"] as? NSNumber)?.doubleValue ?? 0
            let alphaBlend = d["alphaMode"] as? String == "BLEND"
            if alphaBlend || transmission > 0 {
                m.blendMode = .alpha
                m.transparencyMode = .dualLayer
                m.writesToDepthBuffer = false
                m.transparency = CGFloat((alphaBlend ? (base.count > 3 ? base[3] : 1) : 1) * (1 - transmission * 0.75))
            }
            materialCache[index] = m
            return m
        }
    }
}
