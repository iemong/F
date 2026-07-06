import CoreGraphics
import DNGKit
import DecodeKit
import Foundation
import ImageIO

/// デコード済みのCPU側フレーム。テクスチャ化は TextureFactory が行う
struct DisplayFrame: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    /// RGBA8888 row-major
    let rgba: [UInt8]
    let orientation: Orientation
    let fileName: String
    /// パース+デコードに要した時間
    let decodeDuration: Duration
    /// センサーフル解像度相当か
    let isFullResolution: Bool
    /// 論理的なシーン寸法（等倍表示の座標系）
    let sceneWidth: Int
    let sceneHeight: Int
}

enum ImagePipelineError: Error {
    case undecodable(String)
}

extension URL {
    /// 拡張子ベースのJPG判定（表示対象の列挙・デコード経路の分岐で共用）
    var isJPEGFile: Bool {
        let ext = pathExtension.uppercased()
        return ext == "JPG" || ext == "JPEG"
    }
}

/// 画像ファイル → 表示用RGBA。種別・機種別の最適経路を選ぶ:
/// - JPG → そのまま ImageIO でデコード（常にフル解像扱い）
/// - 原寸級JPEG内蔵のDNG（Q3）→ 抽出して ImageIO でデコード
/// - それ以外のDNG（M262）→ LJ92 + ハーフサイズ縮約
enum ImagePipeline {
    static func loadDisplayFrame(from url: URL) throws -> DisplayFrame {
        let clock = ContinuousClock()
        let start = clock.now

        if url.isJPEGFile {
            return try loadJPEGFile(from: url, since: start, clock: clock)
        }

        let file = try DNGFile(contentsOf: url)

        if let preview = file.largestPreview, preview.kind == .fullsize,
            let decoded = decodeJPEGToRGBA(file.previewData(preview))
        {
            return DisplayFrame(
                pixelWidth: decoded.width,
                pixelHeight: decoded.height,
                rgba: decoded.pixels,
                orientation: file.orientation,
                fileName: url.lastPathComponent,
                decodeDuration: clock.now - start,
                isFullResolution: true,
                sceneWidth: decoded.width,
                sceneHeight: decoded.height)
        }

        let image = try DNGDecoder.halfSizeImage(from: file)
        let scene = file.raw?.pixelSize
        return DisplayFrame(
            pixelWidth: image.width,
            pixelHeight: image.height,
            rgba: image.pixels,
            orientation: file.orientation,
            fileName: url.lastPathComponent,
            decodeDuration: clock.now - start,
            isFullResolution: false,
            sceneWidth: scene?.width ?? image.width * 2,
            sceneHeight: scene?.height ?? image.height * 2)
    }

    /// 100%等倍用のフル解像度フレーム。
    /// 原寸級JPEGを持つ機種(Q3)は通常経路と同一、M262はフルデモザイクを遅延実行
    static func loadFullResolutionFrame(from url: URL) throws -> DisplayFrame {
        let clock = ContinuousClock()
        let start = clock.now

        if url.isJPEGFile {
            return try loadJPEGFile(from: url, since: start, clock: clock)
        }

        let file = try DNGFile(contentsOf: url)

        if let preview = file.largestPreview, preview.kind == .fullsize,
            let decoded = decodeJPEGToRGBA(file.previewData(preview))
        {
            return DisplayFrame(
                pixelWidth: decoded.width,
                pixelHeight: decoded.height,
                rgba: decoded.pixels,
                orientation: file.orientation,
                fileName: url.lastPathComponent,
                decodeDuration: clock.now - start,
                isFullResolution: true,
                sceneWidth: decoded.width,
                sceneHeight: decoded.height)
        }

        let image = try DNGDecoder.fullSizeImage(from: file)
        return DisplayFrame(
            pixelWidth: image.width,
            pixelHeight: image.height,
            rgba: image.pixels,
            orientation: file.orientation,
            fileName: url.lastPathComponent,
            decodeDuration: clock.now - start,
            isFullResolution: true,
            sceneWidth: image.width,
            sceneHeight: image.height)
    }

    /// キャッシュミス時の速報表示用: 小さめの埋め込みプレビューを最速でデコードする
    /// （Q3: 1620×1080 / M262: 1472×976、数〜十数ms）。本デコード完了時に差し替える前提。
    /// シーン寸法は loadDisplayFrame と同じ座標系に合わせ、差し替えで表示位置が飛ばないようにする
    static func loadProvisionalFrame(from url: URL) throws -> DisplayFrame {
        let clock = ContinuousClock()
        let start = clock.now

        let file = try DNGFile(contentsOf: url)
        guard
            // 高さ側は3:2/4:3の縦横比を考慮して低めに（Q3中間1620×1080が候補に入るように）
            let preview = file.bestPreview(fitting: PixelSize(width: 1280, height: 720)),
            // fullsize（Q3のJpgFromRaw）しか無い場合は本デコードと同じ仕事になるので速報は出さない
            preview.kind != .fullsize,
            let decoded = decodeJPEGToRGBA(file.previewData(preview))
        else { throw ImagePipelineError.undecodable("速報用プレビューなし") }

        // 本デコードのシーン寸法: Q3=JpgFromRaw寸法 / M262=raw寸法
        let scene: PixelSize =
            if let largest = file.largestPreview, largest.kind == .fullsize {
                largest.pixelSize
            } else {
                file.raw?.pixelSize
                    ?? PixelSize(width: decoded.width, height: decoded.height)
            }
        return DisplayFrame(
            pixelWidth: decoded.width,
            pixelHeight: decoded.height,
            rgba: decoded.pixels,
            orientation: file.orientation,
            fileName: url.lastPathComponent,
            decodeDuration: clock.now - start,
            isFullResolution: false,
            sceneWidth: scene.width,
            sceneHeight: scene.height)
    }

    /// 単体のJPGファイル。JPGはそれ自体が最終画像なので常にフル解像扱い。
    /// Orientation はExifから読み、DNGと同じくテクスチャには焼かずUV割当で正立させる
    private static func loadJPEGFile(
        from url: URL, since start: ContinuousClock.Instant, clock: ContinuousClock
    ) throws -> DisplayFrame {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let decoded = decodeJPEGToRGBA(data) else {
            throw ImagePipelineError.undecodable("JPGデコード失敗")
        }
        return DisplayFrame(
            pixelWidth: decoded.width,
            pixelHeight: decoded.height,
            rgba: decoded.pixels,
            orientation: jpegOrientation(data),
            fileName: url.lastPathComponent,
            decodeDuration: clock.now - start,
            isFullResolution: true,
            sceneWidth: decoded.width,
            sceneHeight: decoded.height)
    }

    private static func jpegOrientation(_ data: Data) -> Orientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let raw = props[kCGImagePropertyOrientation] as? UInt32
        else { return .topLeft }
        return Orientation(rawValue: UInt16(clamping: raw)) ?? .topLeft
    }

    private static func decodeJPEGToRGBA(_ data: Data)
        -> (width: Int, height: Int, pixels: [UInt8])?
    {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
            cgImage.width > 0, cgImage.height > 0
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? (width, height, pixels) : nil
    }
}
