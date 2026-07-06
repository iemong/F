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
/// - JPG → ImageIO でデコード（表示用は画面長辺まで縮小、等倍用は全画素）
/// - 原寸級JPEG内蔵のDNG（Q3）→ 抽出して ImageIO でデコード（同上）
/// - それ以外のDNG（M262）→ LJ92 + ハーフサイズ縮約
enum ImagePipeline {
    /// 表示用フレーム。displayTarget は縮小デコードの目標長辺px（最大スクリーンの長辺）。
    /// 縮小しても scene 寸法は原寸のままなので、等倍表示や差し替えの座標系は変わらない
    static func loadDisplayFrame(from url: URL, displayTarget: Int) throws -> DisplayFrame {
        let clock = ContinuousClock()
        let start = clock.now

        if url.isJPEGFile {
            return try loadJPEGFile(
                from: url, maxPixelSize: displayTarget, since: start, clock: clock)
        }

        let file = try DNGFile(contentsOf: url)

        if let preview = file.largestPreview, preview.kind == .fullsize,
            let decoded = decodeJPEGToRGBA(
                file.previewData(preview), maxPixelSize: displayTarget)
        {
            // 目標より小さい画像は縮小されず原寸のまま返る → フル解像扱い
            let isFull =
                decoded.width >= preview.pixelSize.width
                && decoded.height >= preview.pixelSize.height
            return DisplayFrame(
                pixelWidth: decoded.width,
                pixelHeight: decoded.height,
                rgba: decoded.pixels,
                orientation: file.orientation,
                fileName: url.lastPathComponent,
                decodeDuration: clock.now - start,
                isFullResolution: isFull,
                sceneWidth: preview.pixelSize.width,
                sceneHeight: preview.pixelSize.height)
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
            return try loadJPEGFile(from: url, maxPixelSize: nil, since: start, clock: clock)
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

    /// 単体のJPGファイル。maxPixelSize 指定時は表示用の縮小デコード。
    /// scene 寸法は常に原寸（ヘッダから取得）で、等倍時は full 経路の全画素デコードに差し替わる。
    /// Orientation はExifから読み、DNGと同じくテクスチャには焼かずUV割当で正立させる
    private static func loadJPEGFile(
        from url: URL, maxPixelSize: Int?,
        since start: ContinuousClock.Instant, clock: ContinuousClock
    ) throws -> DisplayFrame {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let decoded = decodeJPEGToRGBA(data, maxPixelSize: maxPixelSize) else {
            throw ImagePipelineError.undecodable("JPGデコード失敗")
        }
        let props = jpegProperties(data)
        let sceneWidth = props.pixelSize?.width ?? decoded.width
        let sceneHeight = props.pixelSize?.height ?? decoded.height
        return DisplayFrame(
            pixelWidth: decoded.width,
            pixelHeight: decoded.height,
            rgba: decoded.pixels,
            orientation: props.orientation,
            fileName: url.lastPathComponent,
            decodeDuration: clock.now - start,
            isFullResolution: decoded.width >= sceneWidth && decoded.height >= sceneHeight,
            sceneWidth: sceneWidth,
            sceneHeight: sceneHeight)
    }

    private static func jpegProperties(_ data: Data)
        -> (orientation: Orientation, pixelSize: PixelSize?)
    {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return (.topLeft, nil) }
        let orientation =
            (props[kCGImagePropertyOrientation] as? UInt32)
            .flatMap { Orientation(rawValue: UInt16(clamping: $0)) } ?? .topLeft
        var pixelSize: PixelSize?
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            pixelSize = PixelSize(width: w, height: h)
        }
        return (orientation, pixelSize)
    }

    /// maxPixelSize 指定時は ImageIO の縮小デコード（libjpeg の DCT スケーリングが効くため
    /// 全画素より数倍速く、メモリも縮小後のみ）。原寸より大きくはならない（アップスケールなし）。
    /// WithTransform=false: Orientation はテクスチャに焼かず UV 割当で解決する方針のため
    private static func decodeJPEGToRGBA(_ data: Data, maxPixelSize: Int? = nil)
        -> (width: Int, height: Int, pixels: [UInt8])?
    {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        let decodedImage: CGImage?
        if let maxPixelSize {
            let thumbOptions =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            decodedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
        } else {
            decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cgImage = decodedImage, cgImage.width > 0, cgImage.height > 0
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
