import SwiftUI
import SceneKit

/// SCNView that renders at a low "pixel" resolution and is upscaled with nearest-neighbour.
final class PixelSCNView: SCNView {
    var shortSide: CGFloat = 540 { didSet { setNeedsLayout() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        let s = min(bounds.width, bounds.height)
        if s > 0 {
            let f = max(0.2, shortSide / s)
            if abs(contentScaleFactor - f) > 0.001 { contentScaleFactor = f; layer.contentsScale = f }
        }
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
    }
}

func pixelTechnique() -> SCNTechnique? {
    let dict: [String: Any] = [
        "passes": [
            "pix_scene": [
                "draw": "DRAW_SCENE",
                "outputs": ["color": "sceneColor", "depth": "sceneDepth"],
                "colorStates": ["clear": true],
                "depthStates": ["clear": true, "enableWrite": true, "enableRead": true],
            ],
            "pix_post": [
                "draw": "DRAW_QUAD",
                "metalVertexShader": "pix_vertex",
                "metalFragmentShader": "pix_fragment",
                "inputs": ["colorTex": "sceneColor", "depthTex": "sceneDepth"],
                "outputs": ["color": "COLOR"],
            ],
        ],
        "sequence": ["pix_scene", "pix_post"],
        "targets": [
            "sceneColor": ["type": "color"],
            "sceneDepth": ["type": "depth"],
        ],
    ]
    return SCNTechnique(dictionary: dict)
}

struct PixelIslandView: UIViewRepresentable {
    let island: IslandScene
    @ObservedObject var model: GameModel

    func makeCoordinator() -> Coordinator { Coordinator(island: island, model: model) }

    func makeUIView(context: Context) -> PixelSCNView {
        let v = PixelSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = island.scene
        v.pointOfView = island.cameraNode
        v.delegate = island
        v.isPlaying = true
        v.rendersContinuously = true
        v.antialiasingMode = .none
        v.usesReverseZ = true
        v.preferredFramesPerSecond = 60
        v.backgroundColor = .black
        if !ProcessInfo.processInfo.arguments.contains("-nopost") { v.technique = pixelTechnique() }
        v.shortSide = CGFloat(model.resolution)
        let c = context.coordinator; c.view = v
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:))); pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        [pan, pinch, tap].forEach { v.addGestureRecognizer($0) }
        return v
    }

    func updateUIView(_ v: PixelSCNView, context: Context) {
        v.shortSide = CGFloat(model.resolution)
    }

    final class Coordinator: NSObject {
        let island: IslandScene; let model: GameModel
        weak var view: PixelSCNView?
        var dragging: Placed?
        var startYaw: Float = 0
        var startScale: Double = 8.5
        init(island: IslandScene, model: GameModel) { self.island = island; self.model = model }

        func groundPoint(_ p: CGPoint, y: Float = 0) -> SCNVector3? {
            guard let v = view else { return nil }
            let a = v.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 0))
            let b = v.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 1))
            let dy = b.y - a.y
            guard abs(dy) > 1e-5 else { return nil }
            let t = (y - a.y) / dy
            return SCNVector3(a.x + (b.x - a.x) * t, y, a.z + (b.z - a.z) * t)
        }

        func hitItem(_ p: CGPoint) -> Placed? {
            guard let v = view else { return nil }
            for h in v.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
                if let it = island.item(for: h.node) { return it }
            }
            return nil
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard model.editMode else { return }
            let it = hitItem(g.location(in: view))
            model.select(it)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            let loc = g.location(in: v)
            switch g.state {
            case .began:
                dragging = model.editMode ? hitItem(loc) : nil
                if let d = dragging { model.select(d) }
                startYaw = island.camPivot.eulerAngles.y
            case .changed:
                if let d = dragging, let gp = groundPoint(loc) {
                    island.place(d, x: gp.x, z: gp.z, snap: !model.freeMode)
                } else if dragging == nil {
                    let tr = g.translation(in: v)
                    island.camPivot.eulerAngles.y = startYaw - Float(tr.x) * 0.008
                }
            default:
                dragging = nil
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let cam = island.cameraNode.camera else { return }
            if g.state == .began { startScale = cam.orthographicScale }
            cam.orthographicScale = min(14, max(3.5, startScale / Double(g.scale)))
        }
    }
}
