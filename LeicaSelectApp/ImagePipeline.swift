import CoreGraphics
import DNGKit
import DecodeKit
import Foundation
import ImageIO

/// 表示直前まで準備できたフレーム。テクスチャ化はレンダラ（メインスレッド）で行う
struct DisplayFrame: Sendable, Identifiable {
    /// ナビゲーション世代。テクスチャ再アップロード判定にも使う
    let id: Int
    let pixelWidth: Int
    let pixelHeight: Int
    /// RGBA8888 row-major
    let rgba: [UInt8]
    let orientation: Orientation
    let fileName: String
    /// パース+デコードに要した時間
    let decodeDuration: Duration
}

enum ImagePipelineError: Error {
    case undecodable(String)
}

/// DNGファイル → 表示用RGBA。機種別の最適経路を選ぶ:
/// - 原寸級JPEG内蔵（Q3）→ 抽出して ImageIO でデコード
/// - それ以外（M262）→ LJ92 + ハーフサイズ縮約
enum ImagePipeline {
    static func loadDisplayFrame(from url: URL, id: Int) throws -> DisplayFrame {
        let clock = ContinuousClock()
        let start = clock.now

        let file = try DNGFile(contentsOf: url)

        if let preview = file.largestPreview, preview.kind == .fullsize,
            let decoded = decodeJPEGToRGBA(file.previewData(preview))
        {
            return DisplayFrame(
                id: id,
                pixelWidth: decoded.width,
                pixelHeight: decoded.height,
                rgba: decoded.pixels,
                orientation: file.orientation,
                fileName: url.lastPathComponent,
                decodeDuration: clock.now - start)
        }

        let image = try DNGDecoder.halfSizeImage(from: file)
        return DisplayFrame(
            id: id,
            pixelWidth: image.width,
            pixelHeight: image.height,
            rgba: image.pixels,
            orientation: file.orientation,
            fileName: url.lastPathComponent,
            decodeDuration: clock.now - start)
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
