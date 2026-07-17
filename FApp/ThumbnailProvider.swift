import AppCore
import CacheKit
import CoreGraphics
import DNGKit
import Foundation
import ImageIO

/// グリッド用サムネイル。CGImage は生成後不変利用の契約で @unchecked Sendable
struct ThumbImage: @unchecked Sendable {
    let cgImage: CGImage
    /// 表示時に適用する回転（度、時計回り）
    let rotationDegrees: Double

    var byteCost: Int { cgImage.width * cgImage.height * 4 }
}

private struct ThumbnailCacheKey: Hashable, Sendable {
    let url: URL
    let byteCount: Int
    let modifiedAt: TimeInterval

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        byteCount = values?.fileSize ?? -1
        modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
    }
}

/// DNGの埋め込みプレビューからサムネイルを生成しLRUキャッシュする。
/// ソースはIFD0サムネ or MakerNotesプレビュー（bestPreviewが機種差を吸収）
final class ThumbnailProvider: Sendable {
    private let cache = LRUByteCache<ThumbnailCacheKey, ThumbImage>(
        byteLimit: 320 * 1024 * 1024
    ) { $0.byteCost }

    func image(for url: URL) async -> ThumbImage? {
        let key = ThumbnailCacheKey(url: url)
        return try? await cache.value(for: key) {
            try Task.checkCancellation()
            return try Self.makeThumbnail(for: url)
        }
    }

    private static func makeThumbnail(for url: URL) throws -> ThumbImage {
        if url.isJPEGFile {
            return try makeJPEGThumbnail(for: url)
        }
        let file = try DNGFile(contentsOf: url)
        // セルサイズ(~200pt=400px)を満たす最小のプレビューを選ぶ
        guard
            let preview = file.bestPreview(fitting: PixelSize(width: 320, height: 320))
                ?? file.largestPreview
        else { throw ImagePipelineError.undecodable("プレビューなし") }

        let data = file.previewData(preview)
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { throw ImagePipelineError.undecodable("サムネ生成失敗") }

        let rotation: Double =
            switch file.orientation {
            case .bottomRight: 180
            case .rightTop: 90
            case .leftBottom: 270
            default: 0
            }
        return ThumbImage(cgImage: thumbnail, rotationDegrees: rotation)
    }

    /// JPGはImageIOがExif orientationを織り込んでくれる（WithTransform）ので回転は0
    private static func makeJPEGThumbnail(for url: URL) throws -> ThumbImage {
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { throw ImagePipelineError.undecodable("JPGサムネ生成失敗") }
        return ThumbImage(cgImage: thumbnail, rotationDegrees: 0)
    }
}

enum ThumbnailAnalysis {
    /// 9×8の輝度差から64bit dHashを作る。大規模モデルを使わない軽量な類似度補正。
    static func perceptualHash(of image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        var bit = 0
        for y in 0 ..< height {
            for x in 0 ..< (width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    hash |= UInt64(1) << UInt64(bit)
                }
                bit += 1
            }
        }
        return hash
    }

    static func qualityMetrics(of image: CGImage) -> QualityMetrics? {
        let width = 160
        let height = 160
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return TechnicalQualityAnalyzer.analyze(luma: pixels, width: width, height: height)
    }
}

/// 将来Vision顔検出を追加する際の差し込み口。初期版では実装を注入しない。
protocol OptionalFaceAnalysisProviding {
    func faceCount(in thumbnail: CGImage) -> Int?
}
