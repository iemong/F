import Foundation
import Testing
import DNGKit

/// リファレンス値は docs/dng-analysis.md の exiftool/xxd 実測値
@Suite("Q3 L1030505 の精密パース", .enabled(if: Fixtures.hasSamples))
struct Q3Tests {
    let file: DNGFile

    init() throws {
        file = try DNGFile(contentsOf: Fixtures.url("L1030505.DNG"))
    }

    @Test func リトルエンディアンである() {
        #expect(file.byteOrder == .little)
    }

    @Test func モデル名() {
        #expect(file.model == "LEICA Q3")
    }

    @Test func 横位置() {
        #expect(file.orientation == .topLeft)
    }

    @Test func raw情報() throws {
        let raw = try #require(file.raw)
        #expect(raw.pixelSize == PixelSize(width: 5312, height: 3526))
        #expect(raw.bitsPerSample == 14)
        #expect(raw.compression == 7) // lossless JPEG (LJ92)
        #expect(raw.byteRanges == [2_993_086 ..< (2_993_086 + 19_859_155)])
    }

    @Test func プレビューは3つで面積降順() {
        #expect(file.previews.count == 3)
        let areas = file.previews.map(\.pixelSize.area)
        #expect(areas == areas.sorted(by: >))
    }

    @Test func 原寸JPEG_JpgFromRaw() throws {
        let p = try #require(file.previews.first)
        #expect(p.kind == .fullsize)
        #expect(p.source == .subIFD(2))
        #expect(p.pixelSize == PixelSize(width: 5288, height: 3518))
        #expect(p.byteRange.count == 2_607_113)
        #expect(file.previewData(p).prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func 中間プレビュー() throws {
        let p = try #require(file.previews.dropFirst().first)
        #expect(p.kind == .midsize)
        #expect(p.source == .subIFD(1))
        #expect(p.pixelSize == PixelSize(width: 1620, height: 1080))
        #expect(p.byteRange.count == 273_035)
    }

    @Test func サムネイル() throws {
        let p = try #require(file.previews.last)
        #expect(p.kind == .thumbnail)
        #expect(p.source == .ifd0)
        #expect(p.pixelSize == PixelSize(width: 720, height: 480))
        #expect(p.byteRange.count == 78_842)
    }

    @Test func 要求寸法以上の最小プレビューを選ぶ() {
        #expect(
            file.bestPreview(fitting: PixelSize(width: 800, height: 600))?.pixelSize
                == PixelSize(width: 1620, height: 1080))
        #expect(
            file.bestPreview(fitting: PixelSize(width: 2560, height: 1440))?.pixelSize
                == PixelSize(width: 5288, height: 3518))
    }
}
