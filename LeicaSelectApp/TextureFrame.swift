import DNGKit
import Foundation
import Metal

/// プロセス共通の Metal デバイス。
/// MTLDevice はスレッドセーフ（リソース生成はどのスレッドからでも可）なため、
/// 不変シングルトンとして @unchecked Sendable で共有する
final class GPUContext: @unchecked Sendable {
    static let shared = GPUContext()
    let device: MTLDevice?
    private init() {
        device = MTLCreateSystemDefaultDevice()
    }
}

/// アップロード済みテクスチャ1枚分。
/// 生成完了後にテクスチャ内容を変更しない契約のもとで @unchecked Sendable
/// （不変利用の MTLTexture はスレッド間で安全に受け渡せる）
struct TextureFrame: @unchecked Sendable {
    let texture: any MTLTexture
    let orientation: Orientation
    let fileName: String
    /// パース+デコード+アップロードに要した時間
    let decodeDuration: Duration

    var byteCost: Int { texture.width * texture.height * 4 }
}

/// 表示中フレーム（UI層専用）。generation は present 計測の世代ガードに使う
struct PresentedFrame {
    let generation: Int
    let frame: TextureFrame
}

enum TextureFrameError: Error {
    case noMetalDevice
    case textureCreationFailed
}

enum TextureFactory {
    /// CPU フレーム → 共有ストレージのテクスチャ。バックグラウンドスレッドから呼んでよい
    static func makeFrame(from frame: DisplayFrame) throws -> TextureFrame {
        guard let device = GPUContext.shared.device else {
            throw TextureFrameError.noMetalDevice
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: frame.pixelWidth,
            height: frame.pixelHeight,
            mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TextureFrameError.textureCreationFailed
        }
        frame.rgba.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.pixelWidth, frame.pixelHeight),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: frame.pixelWidth * 4)
        }
        return TextureFrame(
            texture: texture,
            orientation: frame.orientation,
            fileName: frame.fileName,
            decodeDuration: frame.decodeDuration)
    }
}
