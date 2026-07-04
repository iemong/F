import DNGKit
import Foundation
import Testing
@testable import DecodeKit

@Suite("FullDemosaicRenderer")
struct FullDemosaicTests {
    private func grayRaw(
        width: Int, height: Int, cfa: [UInt8],
        black: Double, white: Double, neutral: [Double]
    ) -> RawImage {
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let channel = Int(cfa[(y % 2) * 2 + (x % 2)])
                samples[y * width + x] =
                    UInt16(black + 0.5 * (white - black) * neutral[channel])
            }
        }
        return RawImage(width: width, height: height, bitDepth: 14, samples: samples)
    }

    @Test(arguments: [
        [UInt8]([0, 1, 1, 2]), // RGGB (Q3)
        [UInt8]([2, 1, 1, 0]), // BGGR (M262)
    ])
    func ニュートラルグレーはグレーのまま出力される(cfa: [UInt8]) throws {
        let neutral = [0.8, 1.0, 0.3]
        let raw = grayRaw(
            width: 8, height: 8, cfa: cfa, black: 512, white: 16383, neutral: neutral)
        let matrix = [0.6602, -0.0788, -0.0864, -0.3621, 1.2513, 0.0657, -0.0683, 0.1368, 0.2922]
        let image = FullDemosaicRenderer.render(
            raw: raw, cfaPattern: cfa,
            blackLevels: [512, 512, 512, 512], whiteLevel: 16383,
            asShotNeutral: neutral, colorMatrix2: matrix)

        // 出力はフル解像度
        #expect(image.width == 8)
        #expect(image.height == 8)

        let expected = Int(255.0 * (1.055 * pow(0.5, 1 / 2.4) - 0.055))
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
            #expect(abs(r - expected) <= 2)
            #expect(abs(r - g) <= 1 && abs(g - b) <= 1, "グレーでない: \(r),\(g),\(b)")
            #expect(image.pixels[i + 3] == 255)
        }
    }

    @Test func ハーフサイズ版と平均輝度が一致する() throws {
        // 擬似ランダムなrawで、フルデモザイクとハーフサイズの平均Gが近いこと
        var rng = SeededRandom(seed: 99)
        let width = 32, height = 32
        let samples = (0 ..< width * height).map { _ in UInt16(rng.next(below: 16384)) }
        let raw = RawImage(width: width, height: height, bitDepth: 14, samples: samples)
        let args: ([UInt8], [Double], Int, [Double]?, [Double]?) =
            ([0, 1, 1, 2], [0, 0, 0, 0], 16383, nil, nil)

        let full = FullDemosaicRenderer.render(
            raw: raw, cfaPattern: args.0, blackLevels: args.1, whiteLevel: args.2,
            asShotNeutral: args.3, colorMatrix2: args.4)
        let half = HalfSizeRenderer.render(
            raw: raw, cfaPattern: args.0, blackLevels: args.1, whiteLevel: args.2,
            asShotNeutral: args.3, colorMatrix2: args.4)

        func averageGreen(_ image: RGBA8Image) -> Double {
            var sum = 0
            for i in stride(from: 0, to: image.pixels.count, by: 4) {
                sum += Int(image.pixels[i + 1])
            }
            return Double(sum) / Double(image.width * image.height)
        }
        #expect(abs(averageGreen(full) - averageGreen(half)) < 4.0)
    }

    @Test func M262フィクスチャのフルデモザイク(
    ) throws {
        guard Fixtures.hasSamples else { return }
        let file = try DNGFile(contentsOf: Fixtures.url("L1007057.DNG"))
        let image = try DNGDecoder.fullSizeImage(from: file)
        #expect(image.width == 5984)
        #expect(image.height == 4000)

        // 全黒/全白でないスモークチェック
        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: image.pixels.count, by: 4 * 97) {
            histogram[Int(image.pixels[i + 1])] += 1
        }
        let total = histogram.reduce(0, +)
        #expect(histogram[0] < total / 2)
        #expect(histogram[255] < total / 2)
    }
}
