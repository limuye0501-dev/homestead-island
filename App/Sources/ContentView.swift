import SwiftUI
import SceneKit

final class GameModel: ObservableObject {
    let island = IslandScene()
    @Published var hour: Double = 10 { didSet { island.targetHour = Float(hour) } }
    @Published var weather: Weather = .clear { didSet { island.weather = weather } }
    @Published var resolution: Double = 540
    @Published var editMode = false
    @Published var freeMode = false
    @Published var showHUD = true
    @Published var selectedName: String? = nil
    private(set) var selected: Placed?

    init() {
        let args = ProcessInfo.processInfo.arguments
        func val(_ k: String) -> String? { if let i = args.firstIndex(of: k), i + 1 < args.count { return args[i + 1] }; return nil }
        if let h = val("-hour").flatMap(Double.init) { hour = h }
        if let w = val("-weather").flatMap(Weather.init(rawValue:)) { weather = w }
        if let r = val("-res").flatMap(Double.init) { resolution = r }
        if args.contains("-edit") { editMode = true }
        if args.contains("-nohud") { showHUD = false }
        if args.contains("-tour") { island.tour = true; showHUD = false }
        island.targetHour = Float(hour); island.hour = Float(hour); island.weather = weather
        island.apply(dt: 0)
        if args.contains("-edit") { select(island.items.first) }
    }

    func select(_ p: Placed?) {
        selected?.node.opacity = 1
        selected = p
        selectedName = p?.kind.label
        if let n = p?.node {
            n.removeAction(forKey: "sel")
            n.runAction(.sequence([.moveBy(x: 0, y: 0.25, z: 0, duration: 0.1), .moveBy(x: 0, y: -0.25, z: 0, duration: 0.15)]), forKey: "sel")
        }
    }

    func add(_ k: ItemKind) {
        let ang = Float.random(in: 0..<(2 * .pi))
        let n = island.addItem(k, at: SCNVector3(cos(ang) * 1.5, 0, 0.5 + sin(ang) * 1.5))
        if let p = island.items.first(where: { $0.node === n }) {
            island.place(p, x: n.position.x, z: n.position.z, snap: !freeMode)
            select(p)
        }
    }

    func rotateSelected() {
        guard let n = selected?.node else { return }
        let step: Float = .pi / 4
        n.runAction(.rotateBy(x: 0, y: CGFloat(step), z: 0, duration: 0.15))
    }

    func deleteSelected() {
        guard let p = selected else { return }
        p.node.removeFromParentNode()
        island.items.removeAll { $0.node === p.node }
        selected = nil; selectedName = nil
    }
}

struct ContentView: View {
    @StateObject private var model = GameModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            PixelIslandView(island: model.island, model: model).ignoresSafeArea()
            if model.showHUD { hud }
        }
    }

    var timeLabel: String {
        let h = Int(model.hour) % 24, m = Int((model.hour - floor(model.hour)) * 60)
        return String(format: "%02d:%02d", h, m)
    }

    var hud: some View {
        VStack(spacing: 10) {
            if model.editMode {
                HStack(spacing: 8) {
                    ForEach(ItemKind.allCases, id: \.self) { k in
                        Button(k.label) { model.add(k) }.buttonStyle(.borderedProminent).tint(Color(red: 1, green: 0.62, blue: 0.7))
                    }
                }.font(.caption.bold())
                HStack {
                    Text(model.selectedName.map { "已选：\($0)" } ?? "拖动物件移动；点空地取消").font(.caption)
                    Spacer()
                    Toggle(model.freeMode ? "自由" : "半格", isOn: $model.freeMode).toggleStyle(.button).font(.caption)
                    Button("转45°") { model.rotateSelected() }.font(.caption)
                    Button("删除", role: .destructive) { model.deleteSelected() }.font(.caption)
                }
            }
            HStack {
                Image(systemName: model.hour >= 6 && model.hour < 19 ? "sun.max.fill" : "moon.stars.fill").foregroundStyle(.orange)
                Text(timeLabel).monospacedDigit().frame(width: 48)
                Slider(value: $model.hour, in: 0...23.99)
            }
            HStack {
                Picker("天气", selection: $model.weather) {
                    ForEach(Weather.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(width: 170)
                Spacer()
                Button(model.editMode ? "完成" : "装修") { model.editMode.toggle(); if !model.editMode { model.select(nil) } }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.98, green: 0.6, blue: 0.45))
            }
            HStack {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(.pink)
                Text("像素 \(Int(model.resolution))").monospacedDigit().font(.caption).frame(width: 70)
                Slider(value: $model.resolution, in: 270...1080, step: 30)
            }
        }
        .font(.subheadline)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}
