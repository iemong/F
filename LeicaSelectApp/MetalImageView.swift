import AppKit
import DNGKit
import Metal
import QuartzCore
import SwiftUI

/// CAMetalLayer 直叩きの画像表示ビュー。
/// アスペクトフィット / 100%等倍（パン付き）と Orientation 回転をクアッドで解決する
struct MetalImageView: NSViewRepresentable {
    let presented: PresentedFrame
    let zoomMode: ZoomMode
    /// 引数は presentされたフレームのgeneration と実提示時刻（CACurrentMediaTime基準）。
    /// generation は古いフレームの再描画と区別するために使う
    let onPresent: @MainActor (Int, CFTimeInterval) -> Void
    /// 生成された NSView をモデルへ渡す（キー送りヒット時に SwiftUI の
    /// 更新サイクル1フレームを待たず直接描画するための経路）
    let register: @MainActor (MetalLayerView) -> Void

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        register(view)
        return view
    }

    func updateNSView(_ view: MetalLayerView, context: Context) {
        view.onPresent = onPresent
        view.setZoomMode(zoomMode)
        view.show(presented)
    }
}

final class MetalLayerView: NSView {
    private var renderer: QuadRenderer?
    private var currentFrame: PresentedFrame?
    private var zoomMode: ZoomMode = .fit
    /// シーン座標(=デバイスpx)での中心からの平行移動。等倍時のみ有効
    private var panOffset = CGPoint.zero

    /// 同一条件の二重エンコードを防ぐ（直接描画とSwiftUI更新の重複で
    /// drawableキューが飽和し、presentが1フレーム遅れるのを避ける）
    private var renderedGeneration = -1
    private var renderedSize = CGSize.zero
    private var renderedZoom: ZoomMode = .fit
    private var renderedPan = CGPoint.zero

    var onPresent: (@MainActor (Int, CFTimeInterval) -> Void)?

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    override var acceptsFirstResponder: Bool { false }

    func show(_ presented: PresentedFrame) {
        if renderer == nil {
            renderer = QuadRenderer()
            metalLayer?.device = renderer?.device
        }
        if currentFrame?.generation != presented.generation {
            currentFrame = presented
            renderer?.texture = presented.frame.texture
        }
        render()
    }

    func setZoomMode(_ mode: ZoomMode) {
        guard zoomMode != mode else { return }
        zoomMode = mode
        panOffset = .zero
        render()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        render()
    }

    // 等倍時のドラッグでパン
    override func mouseDragged(with event: NSEvent) {
        guard zoomMode == .actualSize else { return }
        let scale = window?.backingScaleFactor ?? 2
        panOffset.x += event.deltaX * scale
        panOffset.y -= event.deltaY * scale // 画面下ドラッグ=コンテンツ下移動(NDCは上が正)
        clampPan()
        render()
    }

    private func clampPan() {
        guard let frame = currentFrame?.frame, let metalLayer else { return }
        let swaps = frame.orientation.swapsDimensions
        let sceneW = CGFloat(swaps ? frame.sceneHeight : frame.sceneWidth)
        let sceneH = CGFloat(swaps ? frame.sceneWidth : frame.sceneHeight)
        let maxX = max(0, (sceneW - metalLayer.drawableSize.width) / 2)
        let maxY = max(0, (sceneH - metalLayer.drawableSize.height) / 2)
        panOffset.x = min(max(panOffset.x, -maxX), maxX)
        panOffset.y = min(max(panOffset.y, -maxY), maxY)
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    private func render() {
        guard let renderer, let metalLayer, let presented = currentFrame,
            metalLayer.drawableSize.width > 0
        else { return }
        if zoomMode == .actualSize { clampPan() }
        if renderedGeneration == presented.generation,
            renderedSize == metalLayer.drawableSize,
            renderedZoom == zoomMode,
            renderedPan == panOffset
        {
            return
        }
        renderedGeneration = presented.generation
        renderedSize = metalLayer.drawableSize
        renderedZoom = zoomMode
        renderedPan = panOffset
        let callback = onPresent
        let generation = presented.generation
        renderer.draw(
            into: metalLayer, frame: presented.frame, zoom: zoomMode, pan: panOffset
        ) { presentedTime in
            if let callback {
                Task { @MainActor in callback(generation, presentedTime) }
            }
        }
    }
}

/// テクスチャ1枚をフィット/等倍で描くだけの最小レンダラ
@MainActor
final class QuadRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// 表示するテクスチャ（アップロード済みを直接受け取る）
    var texture: (any MTLTexture)?

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut quad_vertex(
            uint vid [[vertex_id]],
            constant float4 *vertices [[buffer(0)]]
        ) {
            VertexOut out;
            float4 v = vertices[vid];
            out.position = float4(v.xy, 0.0, 1.0);
            out.uv = v.zw;
            return out;
        }

        fragment float4 quad_fragment(
            VertexOut in [[stage_in]],
            texture2d<float> tex [[texture(0)]]
        ) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            return tex.sample(s, in.uv);
        }
        """

    init?() {
        guard let device = GPUContext.shared.device,
            let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "quad_vertex"),
            let fragmentFunction = library.makeFunction(name: "quad_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = state
    }

    func draw(
        into layer: CAMetalLayer,
        frame: TextureFrame,
        zoom: ZoomMode,
        pan: CGPoint,
        onPresent: @escaping @Sendable (CFTimeInterval) -> Void
    ) {
        guard let texture,
            let drawable = layer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // ジオメトリはシーン寸法（フル解像度px）基準。
        // ハーフサイズテクスチャでも等倍座標系が変わらないので、
        // フル解像への差し替え時に表示位置が飛ばない
        let orientation = frame.orientation
        let sceneWidth =
            orientation.swapsDimensions ? CGFloat(frame.sceneHeight) : CGFloat(frame.sceneWidth)
        let sceneHeight =
            orientation.swapsDimensions ? CGFloat(frame.sceneWidth) : CGFloat(frame.sceneHeight)
        let drawableSize = layer.drawableSize

        let quadWidthPx: CGFloat
        let quadHeightPx: CGFloat
        let centerOffset: CGPoint
        switch zoom {
        case .fit:
            let scale = min(drawableSize.width / sceneWidth, drawableSize.height / sceneHeight)
            quadWidthPx = sceneWidth * scale
            quadHeightPx = sceneHeight * scale
            centerOffset = .zero
        case .actualSize:
            // 1シーンpx = 1デバイスpx
            quadWidthPx = sceneWidth
            quadHeightPx = sceneHeight
            centerOffset = pan
        }

        let ndcHalfWidth = Float(quadWidthPx / drawableSize.width)
        let ndcHalfHeight = Float(quadHeightPx / drawableSize.height)
        let ndcCenterX = Float(2 * centerOffset.x / drawableSize.width)
        let ndcCenterY = Float(2 * centerOffset.y / drawableSize.height)

        // コーナー順: 左下・右下・左上・右上（triangle strip）
        let uv = Self.cornerUVs(for: orientation)
        var vertices: [SIMD4<Float>] = [
            SIMD4(ndcCenterX - ndcHalfWidth, ndcCenterY - ndcHalfHeight, uv[0].x, uv[0].y),
            SIMD4(ndcCenterX + ndcHalfWidth, ndcCenterY - ndcHalfHeight, uv[1].x, uv[1].y),
            SIMD4(ndcCenterX - ndcHalfWidth, ndcCenterY + ndcHalfHeight, uv[2].x, uv[2].y),
            SIMD4(ndcCenterX + ndcHalfWidth, ndcCenterY + ndcHalfHeight, uv[3].x, uv[3].y),
        ]

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(
            &vertices, length: MemoryLayout<SIMD4<Float>>.stride * 4, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        drawable.addPresentedHandler { presented in
            onPresent(presented.presentedTime)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// EXIF Orientation → 画面コーナー（左下・右下・左上・右上）へのUV割り当て。
    /// テクスチャは格納された向きのまま、UVの回転だけで正立表示にする
    private static func cornerUVs(for orientation: Orientation) -> [SIMD2<Float>] {
        switch orientation {
        case .bottomRight: // 180°
            [SIMD2(1, 0), SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1)]
        case .rightTop: // 90° CW（格納行0が表示右側、格納列0が表示上側）
            [SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 1), SIMD2(0, 0)]
        case .leftBottom: // 270° CW（格納行0が表示左側、格納列0が表示下側）
            [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 0), SIMD2(1, 1)]
        default: // 正立（ミラー系は撮影では発生しないため正立扱い）
            [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)]
        }
    }
}
