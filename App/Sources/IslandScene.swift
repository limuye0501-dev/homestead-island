import SceneKit
import UIKit

enum Weather: String, CaseIterable, Identifiable {
    case clear, cloudy, rain
    var id: String { rawValue }
    var label: String {
        switch self { case .clear: return "晴"; case .cloudy: return "多云"; case .rain: return "雨" }
    }
}

enum ItemKind: String, CaseIterable {
    case lampPost, lantern, bench, table, flowerPot
    var label: String {
        switch self {
        case .lampPost: return "路灯"; case .lantern: return "灯笼"; case .bench: return "长椅"
        case .table: return "木桌"; case .flowerPot: return "花盆"
        }
    }
    var isSmall: Bool { self == .lantern || self == .flowerPot }
    var glows: Bool { self == .lampPost || self == .lantern }
}

// MARK: - helpers
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
func mat(_ c: UIColor, emission: UIColor? = nil) -> SCNMaterial {
    let m = SCNMaterial()
    m.diffuse.contents = c
    m.lightingModel = .lambert
    if let e = emission { m.emission.contents = e }
    return m
}
func node(_ g: SCNGeometry, _ c: UIColor, _ p: SCNVector3) -> SCNNode {
    g.materials = [mat(c)]
    let n = SCNNode(geometry: g); n.position = p; n.castsShadow = true
    return n
}
private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
private func lerp3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
private func ui(_ v: SIMD3<Float>) -> UIColor { UIColor(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1) }
private func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = min(max((x - e0) / (e1 - e0), 0), 1); return t * t * (3 - 2 * t) }

let swayModifier = """
float t = scn_frame.time;
float ph = _geometry.position.x * 1.7 + _geometry.position.z * 1.3;
_geometry.position.x += sin(t * 1.6 + ph) * 0.035 + sin(t * 0.7) * 0.04;
_geometry.position.z += cos(t * 1.2 + ph) * 0.03;
"""
let waterModifier = """
float t = scn_frame.time;
float2 uv = _surface.diffuseTexcoord;
float w = sin(uv.x * 38.0 + t * 1.8) * sin(uv.y * 31.0 - t * 1.4);
_surface.diffuse.rgb += step(0.86, w) * 0.4;
"""
let fallModifier = """
float t = scn_frame.time;
float2 uv = _surface.diffuseTexcoord;
float s = fract(uv.y * 7.0 - t * 1.6 + sin(uv.x * 23.0) * 0.25);
_surface.diffuse.rgb = mix(_surface.diffuse.rgb, float3(1.0), step(0.78, s) * 0.75);
"""

struct Placed { let kind: ItemKind; let node: SCNNode }

final class IslandScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let camPivot = SCNNode()
    let cameraNode = SCNNode()
    let sun = SCNNode()
    let ambient = SCNNode()
    var lampLights: [SCNLight] = []
    var glowMats: [SCNMaterial] = []
    var windowMats: [SCNMaterial] = []
    var cloudNodes: [SCNNode] = []
    var cloudMat = mat(col(1, 1, 1))
    let smoke = SCNParticleSystem()
    let rain = SCNParticleSystem()
    let fireflies = SCNParticleSystem()
    var items: [Placed] = []
    let itemsRoot = SCNNode()

    // state (written from UI, read on render thread; small races acceptable for prototype)
    var targetHour: Float = 10
    var hour: Float = 10
    var weather: Weather = .clear
    var cloudMix: Float = 0
    var rainMix: Float = 0
    var flash: Float = 0
    var tour = false
    private var lastT: TimeInterval = 0
    private var lastSkyKey = -1

    override init() {
        super.init()
        build()
        apply(dt: 0)
    }

    // MARK: build
    func build() {
        let root = scene.rootNode
        // camera: orthographic isometric, 45° yaw, 30° tilt
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 8.5
        cam.zNear = 1; cam.zFar = 100
        cameraNode.camera = cam
        let dist: Float = 40
        let tilt: Float = 30 * .pi / 180
        cameraNode.position = SCNVector3(0, dist * sin(tilt), dist * cos(tilt))
        cameraNode.eulerAngles = SCNVector3(-tilt, 0, 0)
        camPivot.eulerAngles.y = .pi / 4
        camPivot.position = SCNVector3(0, -0.8, 0)
        camPivot.addChildNode(cameraNode)
        root.addChildNode(camPivot)

        // lights
        let sl = SCNLight(); sl.type = .directional; sl.castsShadow = true
        sl.shadowMapSize = CGSize(width: 2048, height: 2048); sl.shadowSampleCount = 1; sl.shadowRadius = 0
        sl.orthographicScale = 9; sl.shadowColor = UIColor(red: 0.25, green: 0.15, blue: 0.35, alpha: 0.45)
        sl.zNear = 1; sl.zFar = 80
        sun.light = sl; root.addChildNode(sun)
        let al = SCNLight(); al.type = .ambient; ambient.light = al; root.addChildNode(ambient)

        // island
        let top = SCNCylinder(radius: 6, height: 0.8); top.radialSegmentCount = 12
        let grass = node(top, col(0.55, 0.86, 0.42), SCNVector3(0, -0.4, 0)); root.addChildNode(grass)
        let rim = SCNCylinder(radius: 6.05, height: 0.5); rim.radialSegmentCount = 12
        root.addChildNode(node(rim, col(0.78, 0.55, 0.38), SCNVector3(0, -1.0, 0)))
        let cone = SCNCone(topRadius: 6, bottomRadius: 1.2, height: 4); cone.radialSegmentCount = 12
        root.addChildNode(node(cone, col(0.66, 0.45, 0.34), SCNVector3(0, -3.25, 0)))
        let cone2 = SCNCone(topRadius: 1.2, bottomRadius: 0.1, height: 1.6); cone2.radialSegmentCount = 8
        root.addChildNode(node(cone2, col(0.55, 0.38, 0.32), SCNVector3(0, -6.05, 0)))
        // a few floating rocks
        for (x, y, z, r) in [(-7.5, -2.0, 2.0, 0.6), (7.0, -3.0, -1.5, 0.45), (2.0, -4.5, 7.2, 0.35)] {
            let b = SCNBox(width: r * 2, height: r * 1.4, length: r * 2, chamferRadius: 0.05)
            let n = node(b, col(0.62, 0.46, 0.38), SCNVector3(x, y, z))
            let cap = SCNBox(width: r * 2, height: 0.12, length: r * 2, chamferRadius: 0.02)
            cap.materials = [mat(col(0.55, 0.86, 0.42))]
            let c = SCNNode(geometry: cap); c.position.y = Float(r * 0.7); n.addChildNode(c)
            n.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.25, z: 0, duration: 2.5), .moveBy(x: 0, y: -0.25, z: 0, duration: 2.5)])))
            root.addChildNode(n)
        }

        buildCottage(root)
        buildTrees(root)
        buildGarden(root)
        buildPond(root)
        buildCat(root)
        buildClouds(root)
        buildParticles(root)

        root.addChildNode(itemsRoot)
        _ = addItem(.lampPost, at: SCNVector3(0.5, 0, -0.5))
        _ = addItem(.lampPost, at: SCNVector3(-3.5, 0, 2.5))
        _ = addItem(.bench, at: SCNVector3(1.5, 0, 3.5))
        _ = addItem(.table, at: SCNVector3(-1.0, 0, -4.5))
        _ = addItem(.lantern, at: SCNVector3(-1.0, 0.62, -4.5))
        _ = addItem(.lantern, at: SCNVector3(-2.0, 0, 4.0))
    }

    func buildCottage(_ root: SCNNode) {
        let h = SCNNode(); h.position = SCNVector3(-2.2, 0, -1.6); h.eulerAngles.y = 0.0
        h.addChildNode(node(SCNBox(width: 2.4, height: 1.5, length: 2.0, chamferRadius: 0.02), col(1.0, 0.94, 0.84), SCNVector3(0, 0.75, 0)))
        // timber base
        h.addChildNode(node(SCNBox(width: 2.5, height: 0.2, length: 2.1, chamferRadius: 0), col(0.62, 0.42, 0.32), SCNVector3(0, 0.1, 0)))
        let roof = SCNPyramid(width: 2.9, height: 1.3, length: 2.5)
        h.addChildNode(node(roof, col(0.96, 0.52, 0.56), SCNVector3(0, 1.5, 0)))
        h.addChildNode(node(SCNBox(width: 0.35, height: 0.9, length: 0.35, chamferRadius: 0), col(0.75, 0.5, 0.42), SCNVector3(0.7, 2.2, -0.3)))
        // door
        h.addChildNode(node(SCNBox(width: 0.5, height: 0.85, length: 0.05, chamferRadius: 0), col(0.55, 0.34, 0.26), SCNVector3(0.3, 0.6, 1.01)))
        // windows (emissive at night)
        for (x, z, ry) in [(-0.6, 1.01, 0.0), (1.21, 0.0, Double.pi / 2), (-1.21, 0.2, Double.pi / 2)] {
            let wm = mat(col(0.55, 0.75, 0.95)); windowMats.append(wm)
            let g = SCNBox(width: 0.45, height: 0.45, length: 0.04, chamferRadius: 0); g.materials = [wm]
            let w = SCNNode(geometry: g); w.position = SCNVector3(x, 0.9, z); w.eulerAngles.y = Float(ry)
            h.addChildNode(w)
            let fr = node(SCNBox(width: 0.55, height: 0.08, length: 0.06, chamferRadius: 0), col(1, 1, 1), SCNVector3(0, -0.26, 0.01))
            w.addChildNode(fr)
        }
        // warm indoor light
        let il = SCNLight(); il.type = .omni; il.color = col(1.0, 0.75, 0.45); il.attenuationStartDistance = 0.5; il.attenuationEndDistance = 3.5
        let ln = SCNNode(); ln.light = il; ln.position = SCNVector3(-0.2, 0.9, 1.6); h.addChildNode(ln); lampLights.append(il)
        // flower boxes
        h.addChildNode(node(SCNBox(width: 0.55, height: 0.12, length: 0.15, chamferRadius: 0), col(0.62, 0.42, 0.32), SCNVector3(-0.6, 0.62, 1.1)))
        for i in 0..<4 {
            h.addChildNode(node(SCNSphere(radius: 0.06), [col(1, 0.55, 0.7), col(1, 0.95, 0.6)][i % 2], SCNVector3(-0.78 + Double(i) * 0.12, 0.72, 1.1)))
        }
        root.addChildNode(h)
        // smoke from chimney
        let sm = SCNNode(); sm.position = SCNVector3(-2.2 + 0.7, 2.75, -1.6 - 0.3); sm.addParticleSystem(smoke); root.addChildNode(sm)
    }

    func tree(_ root: SCNNode, at p: SCNVector3, leaf: [UIColor], scale: Float) {
        let t = SCNNode(); t.position = p; t.scale = SCNVector3(scale, scale, scale)
        t.addChildNode(node(SCNCylinder(radius: 0.18, height: 1.6), col(0.58, 0.4, 0.32), SCNVector3(0, 0.8, 0)))
        let blobs: [(Float, Float, Float, CGFloat)] = [(0, 2.0, 0, 0.95), (0.6, 1.8, 0.3, 0.7), (-0.55, 1.75, -0.2, 0.7), (0.1, 2.6, -0.1, 0.65), (-0.2, 1.9, 0.6, 0.6)]
        for (i, b) in blobs.enumerated() {
            let s = SCNSphere(radius: b.3); s.segmentCount = 10
            let m = mat(leaf[i % leaf.count]); s.materials = [m]
            s.shaderModifiers = [.geometry: swayModifier]
            let n = SCNNode(geometry: s); n.position = SCNVector3(b.0, b.1, b.2); n.castsShadow = true
            t.addChildNode(n)
        }
        root.addChildNode(t)
    }

    func buildTrees(_ root: SCNNode) {
        tree(root, at: SCNVector3(2.6, 0, -2.4), leaf: [col(1.0, 0.72, 0.84), col(1.0, 0.82, 0.9), col(0.98, 0.62, 0.78)], scale: 1.0)
        tree(root, at: SCNVector3(-4.4, 0, 0.8), leaf: [col(0.45, 0.78, 0.4), col(0.55, 0.85, 0.45)], scale: 0.75)
        tree(root, at: SCNVector3(4.3, 0, 1.0), leaf: [col(0.5, 0.82, 0.42), col(0.62, 0.88, 0.5)], scale: 0.6)
        // fallen petals
        let petals = SCNNode()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<26 {
            let a = Float.random(in: 0..<(2 * .pi), using: &rng), r = Float.random(in: 0.3..<1.8, using: &rng)
            let g = SCNBox(width: 0.12, height: 0.02, length: 0.12, chamferRadius: 0)
            petals.addChildNode(node(g, col(1, 0.78, 0.88), SCNVector3(2.6 + cos(a) * r, 0.01, -2.4 + sin(a) * r)))
        }
        root.addChildNode(petals.flattenedClone())
    }

    func buildGarden(_ root: SCNNode) {
        let g = SCNNode(); g.position = SCNVector3(2.6, 0, 1.4)
        g.addChildNode(node(SCNBox(width: 2.2, height: 0.12, length: 1.6, chamferRadius: 0), col(0.62, 0.42, 0.3), SCNVector3(0, 0.04, 0)))
        for row in 0..<3 { for c in 0..<4 {
            let x = -0.75 + Double(c) * 0.5, z = -0.5 + Double(row) * 0.5
            g.addChildNode(node(SCNSphere(radius: 0.13), col(0.35, 0.72, 0.32), SCNVector3(x, 0.2, z)))
            if row == 1 { g.addChildNode(node(SCNSphere(radius: 0.07), col(1, 0.45, 0.35), SCNVector3(x + 0.08, 0.3, z))) }
        } }
        root.addChildNode(g.flattenedClone())
        // fence
        let f = SCNNode()
        for i in 0..<7 { f.addChildNode(node(SCNBox(width: 0.08, height: 0.4, length: 0.08, chamferRadius: 0), col(1, 0.97, 0.92), SCNVector3(1.3 + Double(i) * 0.4, 0.2, 2.4))) }
        f.addChildNode(node(SCNBox(width: 2.5, height: 0.06, length: 0.05, chamferRadius: 0), col(1, 0.97, 0.92), SCNVector3(2.5, 0.3, 2.4)))
        root.addChildNode(f.flattenedClone())
        // flowers scattered
        let fl = SCNNode()
        let palette = [col(1, 0.6, 0.75), col(1, 1, 1), col(1, 0.88, 0.45), col(0.8, 0.6, 1), col(1, 0.5, 0.55)]
        var seed: UInt64 = 42
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        for _ in 0..<70 {
            let a = rnd() * 2 * .pi, r = 2.0 + rnd() * 3.6
            let p = SCNVector3(cos(a) * r, 0.1, sin(a) * r)
            if p.x < -0.5 && p.x > -3.8 && p.z < 0 && p.z > -3.2 { continue }
            if p.z > 1.3 && p.x > -2 && p.x < 1 { continue }
            let s = SCNBox(width: 0.13, height: 0.13, length: 0.13, chamferRadius: 0.03)
            fl.addChildNode(node(s, palette[Int(rnd() * 4.99)], p))
        }
        root.addChildNode(fl.flattenedClone())
        // path stones
        let path = SCNNode()
        for i in 0..<6 {
            let z = -0.4 + Float(i) * 0.55
            path.addChildNode(node(SCNBox(width: 0.5, height: 0.04, length: 0.38, chamferRadius: 0.05), col(0.92, 0.88, 0.82), SCNVector3(-1.9 + Float(i) * 0.25, 0.02, z)))
        }
        root.addChildNode(path.flattenedClone())
    }

    func buildPond(_ root: SCNNode) {
        let water = mat(col(0.45, 0.8, 0.98)); water.shaderModifiers = [.surface: waterModifier]
        water.lightingModel = .lambert
        let p = SCNCylinder(radius: 1.4, height: 0.06); p.radialSegmentCount = 14; p.materials = [water]
        let pn = SCNNode(geometry: p); pn.position = SCNVector3(-0.5, 0.0, 2.6); root.addChildNode(pn)
        for i in 0..<14 {
            let a = Float(i) / 14 * 2 * .pi
            root.addChildNode(node(SCNBox(width: 0.35, height: 0.18, length: 0.3, chamferRadius: 0.06), col(0.85, 0.82, 0.8), SCNVector3(-0.5 + cos(a) * 1.5, 0.06, 2.6 + sin(a) * 1.5)))
        }
        // lily pads
        for (x, z) in [(-0.9, 2.3), (0.1, 3.0)] {
            root.addChildNode(node(SCNCylinder(radius: 0.2, height: 0.03), col(0.4, 0.75, 0.4), SCNVector3(x, 0.05, z)))
        }
        root.addChildNode(node(SCNSphere(radius: 0.07), col(1, 0.7, 0.85), SCNVector3(-0.9, 0.1, 2.3)))
        // dock
        let d = SCNNode(); d.position = SCNVector3(-1.7, 0.1, 2.2); d.eulerAngles.y = .pi / 4
        for i in 0..<5 { d.addChildNode(node(SCNBox(width: 0.6, height: 0.06, length: 0.2, chamferRadius: 0), col(0.78, 0.56, 0.4), SCNVector3(0, 0, Float(i) * 0.24))) }
        for (x, z) in [(-0.28, 0.0), (0.28, 0.0), (-0.28, 0.96), (0.28, 0.96)] { d.addChildNode(node(SCNCylinder(radius: 0.05, height: 0.4), col(0.6, 0.42, 0.32), SCNVector3(x, -0.05, z))) }
        root.addChildNode(d)
        // stream from pond to edge, then waterfall off the edge
        let streamM = mat(col(0.45, 0.8, 0.98)); streamM.shaderModifiers = [.surface: fallModifier]
        let s = SCNBox(width: 0.7, height: 0.05, length: 2.0, chamferRadius: 0); s.materials = [streamM]
        let sn = SCNNode(geometry: s); sn.position = SCNVector3(-0.5, 0.0, 4.9); root.addChildNode(sn)
        let fallM = mat(col(0.6, 0.86, 1.0)); fallM.shaderModifiers = [.surface: fallModifier]
        fallM.transparency = 0.9; fallM.isDoubleSided = true
        let fall = SCNPlane(width: 0.7, height: 5.5); fall.materials = [fallM]
        let fn = SCNNode(geometry: fall); fn.position = SCNVector3(-0.5, -2.7, 5.95); root.addChildNode(fn)
        // mist
        let mist = SCNParticleSystem()
        mist.birthRate = 30; mist.particleLifeSpan = 1.4; mist.particleSize = 0.12; mist.particleColor = UIColor(white: 1, alpha: 0.7)
        mist.emitterShape = SCNBox(width: 0.7, height: 0.1, length: 0.1, chamferRadius: 0)
        mist.particleVelocity = 0.6; mist.spreadingAngle = 60; mist.acceleration = SCNVector3(0, -0.6, 0)
        mist.isLightingEnabled = false
        let mn = SCNNode(); mn.position = SCNVector3(-0.5, -5.3, 6.0); mn.addParticleSystem(mist); root.addChildNode(mn)
    }

    func buildCat(_ root: SCNNode) {
        let c = SCNNode(); c.position = SCNVector3(0.6, 0, 1.2); c.eulerAngles.y = 0.8
        let fur = col(1.0, 0.68, 0.38)
        c.addChildNode(node(SCNBox(width: 0.3, height: 0.24, length: 0.5, chamferRadius: 0.08), fur, SCNVector3(0, 0.17, 0)))
        let head = node(SCNBox(width: 0.3, height: 0.27, length: 0.27, chamferRadius: 0.07), fur, SCNVector3(0, 0.36, 0.26))
        for x in [-0.09, 0.09] {
            let ear = node(SCNPyramid(width: 0.09, height: 0.1, length: 0.06), fur, SCNVector3(x, 0.13, 0)); head.addChildNode(ear)
            head.addChildNode(node(SCNBox(width: 0.04, height: 0.05, length: 0.01, chamferRadius: 0), col(0.2, 0.15, 0.2), SCNVector3(x * 0.8, 0.02, 0.14)))
        }
        c.addChildNode(head)
        let tail = node(SCNBox(width: 0.06, height: 0.3, length: 0.06, chamferRadius: 0.03), fur, SCNVector3(0, 0.35, -0.27))
        tail.eulerAngles.x = -0.4
        tail.runAction(.repeatForever(.sequence([.rotateTo(x: -0.4, y: 0, z: 0.4, duration: 0.8), .rotateTo(x: -0.4, y: 0, z: -0.4, duration: 0.8)])))
        c.addChildNode(tail)
        head.runAction(.repeatForever(.sequence([.wait(duration: 3), .rotateBy(x: 0, y: 0.5, z: 0, duration: 0.4), .wait(duration: 2), .rotateBy(x: 0, y: -0.5, z: 0, duration: 0.4)])))
        root.addChildNode(c)
    }

    func buildClouds(_ root: SCNNode) {
        cloudMat.lightingModel = .constant
        for (i, p) in [SCNVector3(-6, 3.5, -5), SCNVector3(5, 4.5, -6), SCNVector3(7, 2.5, 4), SCNVector3(-8, 2.0, 5)].enumerated() {
            let c = SCNNode(); c.position = p
            for j in 0..<4 {
                let s = SCNSphere(radius: CGFloat(0.6 + Double((i + j) % 3) * 0.25)); s.segmentCount = 8; s.materials = [cloudMat]
                let n = SCNNode(geometry: s); n.position = SCNVector3(Float(j) * 0.7 - 1, Float(j % 2) * 0.3, 0); n.castsShadow = false
                c.addChildNode(n)
            }
            c.runAction(.repeatForever(.sequence([.moveBy(x: 1.5, y: 0, z: 0.5, duration: 9 + Double(i)), .moveBy(x: -1.5, y: 0, z: -0.5, duration: 9 + Double(i))])))
            root.addChildNode(c); cloudNodes.append(c)
        }
    }

    func buildParticles(_ root: SCNNode) {
        smoke.birthRate = 4; smoke.particleLifeSpan = 3.0; smoke.particleSize = 0.14; smoke.particleSizeVariation = 0.05
        smoke.particleColor = UIColor(white: 1, alpha: 0.85); smoke.particleVelocity = 0.5; smoke.spreadingAngle = 12
        smoke.emittingDirection = SCNVector3(0, 1, 0); smoke.acceleration = SCNVector3(0.15, 0.05, 0)
        smoke.isLightingEnabled = false
        let fade = CAKeyframeAnimation(); fade.values = [0.9, 0.6, 0.0]; fade.keyTimes = [0, 0.6, 1]
        smoke.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]

        rain.birthRate = 0; rain.particleLifeSpan = 1.0; rain.particleSize = 0.025; rain.stretchFactor = 0.06
        rain.particleColor = UIColor(red: 0.8, green: 0.9, blue: 1.0, alpha: 0.7)
        rain.emitterShape = SCNBox(width: 16, height: 0.1, length: 16, chamferRadius: 0)
        rain.particleVelocity = 14; rain.emittingDirection = SCNVector3(0.1, -1, 0); rain.isLightingEnabled = false
        let rn = SCNNode(); rn.position = SCNVector3(0, 10, 0); rn.addParticleSystem(rain); root.addChildNode(rn)

        fireflies.birthRate = 0; fireflies.particleLifeSpan = 4; fireflies.particleSize = 0.05
        fireflies.particleColor = col(1.0, 0.95, 0.45); fireflies.blendMode = .additive
        fireflies.emitterShape = SCNBox(width: 10, height: 1.2, length: 10, chamferRadius: 0)
        fireflies.particleVelocity = 0.25; fireflies.particleVelocityVariation = 0.2; fireflies.spreadingAngle = 180
        fireflies.isLightingEnabled = false
        let blink = CAKeyframeAnimation(); blink.values = [0.0, 1.0, 0.2, 1.0, 0.0]; blink.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        fireflies.propertyControllers = [.opacity: SCNParticlePropertyController(animation: blink)]
        let fn = SCNNode(); fn.position = SCNVector3(0, 0.9, 0); fn.addParticleSystem(fireflies); root.addChildNode(fn)
    }

    // MARK: items
    func makeItem(_ k: ItemKind) -> SCNNode {
        let n = SCNNode(); n.name = "item"
        let wood = col(0.72, 0.5, 0.36)
        func glowBulb(_ g: SCNGeometry, _ p: SCNVector3, range: CGFloat) {
            let m = mat(col(1.0, 0.85, 0.5), emission: col(1.0, 0.8, 0.35)); m.lightingModel = .constant
            g.materials = [m]; glowMats.append(m)
            let b = SCNNode(geometry: g); b.position = p; b.castsShadow = false; n.addChildNode(b)
            let l = SCNLight(); l.type = .omni; l.color = col(1.0, 0.78, 0.45)
            l.attenuationStartDistance = 0.2; l.attenuationEndDistance = range
            let ln = SCNNode(); ln.light = l; ln.position = p; n.addChildNode(ln); lampLights.append(l)
        }
        switch k {
        case .lampPost:
            n.addChildNode(node(SCNCylinder(radius: 0.05, height: 1.4), col(0.3, 0.26, 0.32), SCNVector3(0, 0.7, 0)))
            n.addChildNode(node(SCNBox(width: 0.3, height: 0.06, length: 0.3, chamferRadius: 0), col(0.3, 0.26, 0.32), SCNVector3(0, 1.62, 0)))
            glowBulb(SCNBox(width: 0.22, height: 0.22, length: 0.22, chamferRadius: 0.02), SCNVector3(0, 1.48, 0), range: 3.2)
        case .lantern:
            n.addChildNode(node(SCNBox(width: 0.2, height: 0.04, length: 0.2, chamferRadius: 0), col(0.3, 0.26, 0.32), SCNVector3(0, 0.3, 0)))
            n.addChildNode(node(SCNBox(width: 0.2, height: 0.04, length: 0.2, chamferRadius: 0), col(0.3, 0.26, 0.32), SCNVector3(0, 0.02, 0)))
            glowBulb(SCNBox(width: 0.15, height: 0.24, length: 0.15, chamferRadius: 0.02), SCNVector3(0, 0.16, 0), range: 2.0)
        case .bench:
            n.addChildNode(node(SCNBox(width: 1.0, height: 0.07, length: 0.35, chamferRadius: 0), wood, SCNVector3(0, 0.35, 0)))
            n.addChildNode(node(SCNBox(width: 1.0, height: 0.3, length: 0.06, chamferRadius: 0), wood, SCNVector3(0, 0.55, -0.16)))
            for x in [-0.42, 0.42] { n.addChildNode(node(SCNBox(width: 0.07, height: 0.35, length: 0.3, chamferRadius: 0), col(0.5, 0.34, 0.28), SCNVector3(x, 0.17, 0))) }
        case .table:
            n.addChildNode(node(SCNBox(width: 1.0, height: 0.08, length: 1.0, chamferRadius: 0.02), wood, SCNVector3(0, 0.58, 0)))
            for (x, z) in [(-0.4, -0.4), (0.4, -0.4), (-0.4, 0.4), (0.4, 0.4)] { n.addChildNode(node(SCNBox(width: 0.07, height: 0.55, length: 0.07, chamferRadius: 0), col(0.5, 0.34, 0.28), SCNVector3(x, 0.27, z))) }
            n.addChildNode(node(SCNBox(width: 0.9, height: 0.01, length: 0.35, chamferRadius: 0), col(1, 0.75, 0.8), SCNVector3(0, 0.625, 0)))
        case .flowerPot:
            n.addChildNode(node(SCNCylinder(radius: 0.12, height: 0.2), col(0.9, 0.55, 0.4), SCNVector3(0, 0.1, 0)))
            n.addChildNode(node(SCNSphere(radius: 0.14), col(1, 0.6, 0.78), SCNVector3(0, 0.3, 0)))
        }
        return n
    }

    @discardableResult
    func addItem(_ k: ItemKind, at p: SCNVector3) -> SCNNode {
        let n = makeItem(k); n.position = p
        itemsRoot.addChildNode(n); items.append(Placed(kind: k, node: n))
        apply(dt: 0, force: true)
        return n
    }

    func item(for hit: SCNNode) -> Placed? {
        var n: SCNNode? = hit
        while let c = n { if let p = items.first(where: { $0.node === c }) { return p }; n = c.parent }
        return nil
    }

    /// Snap to half grid (or free) and handle tabletop placement for small items.
    func place(_ p: Placed, x: Float, z: Float, snap: Bool) {
        var x = x, z = z
        if snap { x = (x * 2).rounded() / 2; z = (z * 2).rounded() / 2 }
        let r = sqrt(x * x + z * z); if r > 5.5 { x *= 5.5 / r; z *= 5.5 / r }
        var y: Float = 0
        if p.kind.isSmall {
            for t in items where t.kind == .table && t.node !== p.node {
                if abs(t.node.position.x - x) < 0.5 && abs(t.node.position.z - z) < 0.5 { y = 0.62 }
            }
        }
        p.node.position = SCNVector3(x, y, z)
    }

    // MARK: per-frame
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastT == 0 ? 0 : Float(min(time - lastT, 0.1)); lastT = time
        apply(dt: dt)
    }

    struct Key { let h: Float; let top, bot, sun: SIMD3<Float>; let sunI, amb: Float; let ambC: SIMD3<Float> }
    // bright, pastel, pink-gold palette — day is the hero
    static let keys: [Key] = [
        Key(h: 0, top: [0.16, 0.18, 0.42], bot: [0.42, 0.32, 0.6], sun: [0.6, 0.7, 1.0], sunI: 250, amb: 420, ambC: [0.55, 0.55, 0.9]),
        Key(h: 4.5, top: [0.18, 0.2, 0.45], bot: [0.45, 0.35, 0.62], sun: [0.6, 0.7, 1.0], sunI: 250, amb: 420, ambC: [0.55, 0.55, 0.9]),
        Key(h: 6.5, top: [0.62, 0.66, 0.95], bot: [1.0, 0.74, 0.7], sun: [1.0, 0.75, 0.6], sunI: 900, amb: 650, ambC: [1.0, 0.8, 0.85]),
        Key(h: 9, top: [0.52, 0.8, 1.0], bot: [1.0, 0.9, 0.86], sun: [1.0, 0.96, 0.88], sunI: 1450, amb: 800, ambC: [0.85, 0.85, 1.0]),
        Key(h: 15.5, top: [0.5, 0.78, 1.0], bot: [1.0, 0.88, 0.84], sun: [1.0, 0.94, 0.84], sunI: 1450, amb: 800, ambC: [0.88, 0.85, 1.0]),
        Key(h: 18.2, top: [0.62, 0.55, 0.92], bot: [1.0, 0.66, 0.5], sun: [1.0, 0.68, 0.45], sunI: 1150, amb: 700, ambC: [1.0, 0.72, 0.8]),
        Key(h: 20, top: [0.32, 0.3, 0.66], bot: [0.85, 0.5, 0.6], sun: [0.8, 0.6, 0.9], sunI: 450, amb: 520, ambC: [0.7, 0.6, 0.95]),
        Key(h: 22, top: [0.16, 0.18, 0.42], bot: [0.42, 0.32, 0.6], sun: [0.6, 0.7, 1.0], sunI: 250, amb: 420, ambC: [0.55, 0.55, 0.9]),
        Key(h: 24, top: [0.16, 0.18, 0.42], bot: [0.42, 0.32, 0.6], sun: [0.6, 0.7, 1.0], sunI: 250, amb: 420, ambC: [0.55, 0.55, 0.9]),
    ]

    func apply(dt: Float, force: Bool = false) {
        // smooth time (shortest way around the clock)
        if tour { targetHour = fmodf(targetHour + dt * 0.35, 24); camPivot.eulerAngles.y += dt * 0.08 }
        var d = targetHour - hour
        if d > 12 { d -= 24 } else if d < -12 { d += 24 }
        hour = dt == 0 && !force ? targetHour : fmodf(hour + d * min(1, dt * 2.5) + 24, 24)
        let wc: Float = weather == .clear ? 0 : 1, wr: Float = weather == .rain ? 1 : 0
        let k = dt == 0 ? 1 : min(1, dt * 1.5)
        cloudMix += (wc - cloudMix) * k; rainMix += (wr - rainMix) * k
        if dt == 0 && !force { cloudMix = wc; rainMix = wr }

        let ks = IslandScene.keys
        var i = 0; while i < ks.count - 2 && ks[i + 1].h <= hour { i += 1 }
        let a = ks[i], b = ks[i + 1], t = smooth(0, 1, (hour - a.h) / max(0.001, b.h - a.h))
        var top = lerp3(a.top, b.top, t), bot = lerp3(a.bot, b.bot, t)
        let grey = SIMD3<Float>(0.62, 0.66, 0.74) * (0.4 + 0.6 * (lerp(a.sunI, b.sunI, t) / 1450))
        let ov = cloudMix * 0.45 + rainMix * 0.25
        top = lerp3(top, grey, ov); bot = lerp3(bot, grey * 1.1, ov)
        // lightning
        if rainMix > 0.8 && dt > 0 && Float.random(in: 0..<1) < dt * 0.12 { flash = 1 }
        flash = max(0, flash - dt * 5)
        let fl = flash > 0.5 || (flash > 0.2 && flash < 0.35) ? Float(1) : 0
        top = lerp3(top, [0.95, 0.95, 1.0], fl * 0.8); bot = lerp3(bot, [1, 1, 1], fl * 0.8)

        // sky gradient (regenerated only when it visibly changes)
        let key = Int(top.x * 40) + Int(top.y * 40) * 41 + Int(top.z * 40) * 1681 + Int(bot.x * 40) * 68921 + Int(bot.y * 40) * 2825761 + Int(bot.z * 40) * 115856201
        if key != lastSkyKey { lastSkyKey = key; scene.background.contents = skyImage(top: top, bot: bot) }

        let e = sin((hour - 6) / 12 * .pi)  // sun elevation proxy
        let isDay = e > -0.05
        let elev = isDay ? max(e, 0.18) : max(-e, 0.3)
        let az = (hour / 24) * 2 * .pi + .pi / 3
        sun.position = SCNVector3(cos(az) * 20 * (1 - elev * 0.5), elev * 20, sin(az) * 20 * (1 - elev * 0.5))
        sun.look(at: SCNVector3Zero)
        let sunI = lerp(a.sunI, b.sunI, t) * (1 - cloudMix * 0.55 - rainMix * 0.15)
        sun.light?.intensity = CGFloat(sunI)
        sun.light?.color = ui(lerp3(a.sun, b.sun, t))
        sun.light?.shadowColor = UIColor(red: 0.3, green: 0.18, blue: 0.4, alpha: CGFloat(0.45 * (1 - cloudMix * 0.6)))
        ambient.light?.intensity = CGFloat(lerp(a.amb, b.amb, t) * (1 + cloudMix * 0.15) + fl * 800)
        ambient.light?.color = ui(lerp3(a.ambC, b.ambC, t))

        let night = 1 - smooth(-0.15, 0.35, e)
        let dim = max(night, cloudMix * 0.35 + rainMix * 0.25)
        for l in lampLights { l.intensity = CGFloat(60 + 1100 * dim) }
        for m in glowMats { m.emission.intensity = CGFloat(0.55 + 0.45 * dim) }
        for m in windowMats { m.emission.contents = col(1.0, 0.78, 0.42); m.emission.intensity = CGFloat(0.15 + 0.85 * dim) }
        cloudMat.diffuse.contents = ui(lerp3(lerp3([1, 1, 1], bot, 0.35), [0.6, 0.62, 0.7], cloudMix * 0.7))
        smoke.particleColor = ui(lerp3([1, 1, 1], top, 0.3)).withAlphaComponent(0.85)
        rain.birthRate = CGFloat(rainMix * 900)
        fireflies.birthRate = CGFloat(night * (1 - rainMix) * 10)
    }

    func skyImage(top: SIMD3<Float>, bot: SIMD3<Float>) -> UIImage {
        let h = 64
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: h), format: fmt).image { ctx in
            for y in 0..<h {
                let t = Float(y) / Float(h - 1)
                ui(lerp3(top, bot, smooth(0.1, 0.9, t))).setFill()
                ctx.fill(CGRect(x: 0, y: y, width: 2, height: 1))
            }
        }
    }
}
