import DNGKit
import Foundation
import Testing
@testable import DecodeKit

@Suite("HalfSizeRenderer")
struct HalfSizeRendererTests {
    /// ニュートラルグレーの被写体は WB+行列適用後もグレーのまま出るべき
    @Test func ニュートラルグレーはグレーに写像される() throws {
        let width = 8, height = 8
        let black = 512.0, white = 16383.0
        let neutral = [0.8, 1.0, 0.3]
        let cfa: [UInt8] = [0, 1, 1, 2] // RGGB
        // シーン反射率 0.5 のグレー: raw値 = black + 0.5*(white-black)*neutral[ch]
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let channel = Int(cfa[(y % 2) * 2 + (x % 2)])
                samples[y * width + x] =
                    UInt16(black + 0.5 * (white - black) * neutral[channel])
            }
        }
        let raw = RawImage(width: width, height: height, bitDepth: 14, samples: samples)
        // Q3実機の ColorMatrix2 を使用（グレーはどんな行列でもグレーに保たれるはず）
        let matrix = [0.6602, -0.0788, -0.0864, -0.3621, 1.2513, 0.0657, -0.0683, 0.1368, 0.2922]
        let image = HalfSizeRenderer.render(
            raw: raw, cfaPattern: cfa,
            blackLevels: [black, black, black, black], whiteLevel: Int(white),
            asShotNeutral: neutral, colorMatrix2: matrix)

        #expect(image.width == 4)
        #expect(image.height == 4)
        #expect(image.pixels.count == 4 * 4 * 4)

        // sRGB(0.5) ≈ 188。全画素が同値グレー±2 で出ること
        let expected = Int(255.0 * (1.055 * pow(0.5, 1 / 2.4) - 0.055))
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
            #expect(abs(r - expected) <= 2, "R=\(r) expected≈\(expected)")
            #expect(abs(r - g) <= 1 && abs(g - b) <= 1, "グレーでない: \(r),\(g),\(b)")
            #expect(image.pixels[i + 3] == 255)
        }
    }

    @Test func 黒レベル以下は黒にクリップ() {
        let raw = RawImage(
            width: 4, height: 4, bitDepth: 14,
            samples: [UInt16](repeating: 100, count: 16)) // black=512 より下
        let image = HalfSizeRenderer.render(
            raw: raw, cfaPattern: [0, 1, 1, 2],
            blackLevels: [512, 512, 512, 512], whiteLevel: 16383,
            asShotNeutral: [0.8, 1.0, 0.3], colorMatrix2: nil)
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            #expect(image.pixels[i] == 0)
            #expect(image.pixels[i + 1] == 0)
            #expect(image.pixels[i + 2] == 0)
        }
    }

    @Test func 白レベルは白に飽和() {
        let raw = RawImage(
            width: 4, height: 4, bitDepth: 14,
            samples: [UInt16](repeating: 16383, count: 16))
        let image = HalfSizeRenderer.render(
            raw: raw, cfaPattern: [0, 1, 1, 2],
            blackLevels: [512, 512, 512, 512], whiteLevel: 16383,
            asShotNeutral: [0.8, 1.0, 0.3], colorMatrix2: nil)
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            #expect(image.pixels[i] == 255)
            #expect(image.pixels[i + 1] == 255)
            #expect(image.pixels[i + 2] == 255)
        }
    }
}

@Suite("DNGDecoder フルパイプライン", .enabled(if: Fixtures.hasSamples))
struct DNGDecoderPipelineTests {
    @Test(arguments: [
        ("L1030505.DNG", 2656, 1763), // Q3
        ("L1007057.DNG", 2992, 2000), // M262 (BGGR)
    ])
    func ハーフサイズ画像が生成される(name: String, width: Int, height: Int) throws {
        let file = try DNGFile(contentsOf: Fixtures.url(name))
        let image = try DNGDecoder.halfSizeImage(from: file)
        #expect(image.width == width)
        #expect(image.height == height)
        #expect(image.pixels.count == width * height * 4)

        // 全黒/全白でないこと（デコード結果が実画像であることのスモークチェック）
        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            histogram[Int(image.pixels[i + 1])] += 1 // Gチャンネル
        }
        let total = width * height
        #expect(histogram[0] < total / 2, "\(name): 半分以上が黒")
        #expect(histogram[255] < total / 2, "\(name): 半分以上が白")
    }
}
