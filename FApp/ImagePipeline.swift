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

/// DNGファイル → 表示用RGBA。機種別の最適経路を選ぶ:
/// - 原寸級JPEG内蔵（Q3）→ 抽出して ImageIO でデコード
/// - それ以外（M262）→ LJ92 + ハーフサイズ縮約
enum ImagePipeline {
    static func loadDisplayFrame(from url: URL) throws -> DisplayFrame {
        let clock = ContinuousClock()
        let start = clock.now

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
