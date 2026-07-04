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

/// DNGの埋め込みプレビューからサムネイルを生成しLRUキャッシュする。
/// ソースはIFD0サムネ or MakerNotesプレビュー（bestPreviewが機種差を吸収）
final class ThumbnailProvider: Sendable {
    private let cache = LRUByteCache<URL, ThumbImage>(
        byteLimit: 320 * 1024 * 1024
    ) { $0.byteCost }

    func image(for url: URL) async -> ThumbImage? {
        try? await cache.value(for: url) {
            try Task.checkCancellation()
            return try Self.makeThumbnail(for: url)
        }
    }

    private static func makeThumbnail(for url: URL) throws -> ThumbImage {
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
}
