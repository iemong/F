import Foundation
import Testing
import DNGKit

/// リファレンス値は docs/dng-analysis.md の exiftool/xxd 実測値
@Suite("M262 L1007057 の精密パース", .enabled(if: Fixtures.hasSamples))
struct M262Tests {
    let file: DNGFile

    init() throws {
        file = try DNGFile(contentsOf: Fixtures.url("L1007057.DNG"))
    }

    @Test func ビッグエンディアンである() {
        #expect(file.byteOrder == .big)
    }

    @Test func モデル名() {
        #expect(file.model == "LEICA M (Typ 262)")
    }

    @Test func raw情報() throws {
        let raw = try #require(file.raw)
        #expect(raw.pixelSize == PixelSize(width: 5984, height: 4000))
        #expect(raw.bitsPerSample == 16)
        #expect(raw.compression == 7) // M262もLJ92圧縮
        #expect(raw.byteRanges == [14_782 ..< (14_782 + 26_240_476)])
    }

    @Test func センサー色情報() throws {
        let raw = try #require(file.raw)
        #expect(raw.cfaPattern == [2, 1, 1, 0]) // BGGR（Q3と逆）
        #expect(raw.blackLevels == [0, 0, 0, 0]) // スカラー0が4要素に展開される
        #expect(raw.whiteLevel == 15_000)

        let neutral = try #require(file.asShotNeutral)
        #expect(abs(neutral[0] - 0.4539007092) < 1e-6)
        #expect(abs(neutral[2] - 0.7852760736) < 1e-6)

        let matrix = try #require(file.colorMatrix2)
        #expect(matrix.count == 9)
        #expect(abs(matrix[0] - 0.6653) < 1e-6)
    }

    @Test func プレビューは2つ() {
        #expect(file.previews.count == 2)
    }

    @Test func rawの一括読み込みはスライスと同内容() throws {
        let sliced = try #require(file.rawData())
        let contiguous = try #require(file.rawDataContiguous())
        #expect(sliced == contiguous)
        #expect(contiguous.count == 26_240_476)
    }

    @Test func MakerNotesプレビュー() throws {
        let p = try #require(file.previews.first)
        #expect(p.kind == .midsize)
        #expect(p.source == .makerNote)
        #expect(p.pixelSize == PixelSize(width: 1472, height: 976))
        #expect(p.byteRange.count == 366_592)
        #expect(file.previewData(p).prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func 極小サムネイル() throws {
        let p = try #require(file.previews.last)
        #expect(p.kind == .thumbnail)
        #expect(p.source == .ifd0)
        #expect(p.pixelSize == PixelSize(width: 160, height: 120))
        #expect(p.byteRange == 4_096 ..< (4_096 + 9_921))
    }

    @Test func 十分な解像度がなければ最大プレビューにフォールバック() {
        // 800×600 を満たす最小 = MakerNotes 1472×976
        #expect(
            file.bestPreview(fitting: PixelSize(width: 800, height: 600))?.source
                == .makerNote)
        // 2560×1440 を満たすものは無い → 最大(=MakerNotes)にフォールバック
        #expect(
            file.bestPreview(fitting: PixelSize(width: 2560, height: 1440))?.source
                == .makerNote)
    }
}

@Suite("Orientation タグ", .enabled(if: Fixtures.hasSamples))
struct OrientationTests {
    @Test func 縦位置270度_M262() throws {
        let file = try DNGFile(contentsOf: Fixtures.url("L1007062.DNG"))
        #expect(file.orientation == .leftBottom) // 8
        #expect(file.orientation.swapsDimensions)
    }

    @Test func 縦位置90度_Q3() throws {
        let file = try DNGFile(contentsOf: Fixtures.url("L1030513.DNG"))
        #expect(file.orientation == .rightTop) // 6
        #expect(file.orientation.swapsDimensions)
    }
}

@Suite("全サンプルコーパス", .enabled(if: Fixtures.hasSamples))
struct CorpusTests {
    @Test func 全DNGがパースでき不変条件を満たす() throws {
        let urls = try Fixtures.allDNGs()
        #expect(!urls.isEmpty)
        for url in urls {
            let file = try DNGFile(contentsOf: url)
            let name = url.lastPathComponent

            #expect(file.model?.hasPrefix("LEICA") == true, "\(name): model")
            #expect(file.raw != nil, "\(name): raw欠落")

            // セレクトビューワーとして最低限使える解像度のプレビューが必ずある
            let largest = try #require(file.largestPreview, "\(name): プレビューなし")
            #expect(largest.pixelSize.width >= 1472, "\(name): 最大プレビューが小さすぎる")

            for p in file.previews {
                let data = file.previewData(p)
                #expect(data.count == p.byteRange.count, "\(name): 切り出しサイズ不一致")
                #expect(data.prefix(2) == Data([0xFF, 0xD8]), "\(name): JPEGマジック不一致")
            }
        }
    }
}
