import DNGKit
import Foundation
import Testing
@testable import DecodeKit

/// 期待値はすべて rawpy (libraw) の raw_image 出力から採取した正解データ。
/// 採取スクリプトと値の由来は .claude/tasks/ の Phase 2 記録を参照
@Suite("実機DNGのLJ92デコード", .enabled(if: Fixtures.hasSamples))
struct FixtureDecodeTests {
    private func decode(_ name: String) throws -> RawImage {
        let file = try DNGFile(contentsOf: Fixtures.url(name))
        let data = try #require(file.rawData())
        return try LJ92Decoder.decode(data)
    }

    @Test func Q3_L1030505がlibrawと一致() throws {
        let image = try decode("L1030505.DNG")
        #expect(image.width == 5312)
        #expect(image.height == 3526)
        #expect(image.bitDepth == 14)

        #expect(Array(image.samples[0 ..< 8]) == [544, 561, 550, 565, 564, 581, 558, 569])
        #expect(
            Array(image.samples[5312 ..< 5320]) == [559, 533, 561, 529, 569, 534, 567, 533])
        let center = 1763 * 5312 + 2656
        #expect(
            Array(image.samples[center ..< center + 8])
                == [1327, 657, 887, 627, 1178, 659, 1117, 687])
        let tail = 3526 * 5312 - 8
        #expect(Array(image.samples[tail...]) == [0, 0, 136, 0, 0, 0, 0, 0])

        let sum = image.samples.reduce(UInt64(0)) { $0 + UInt64($1) }
        #expect(sum == 33_291_793_235)
        #expect(image.samples.max() == 16383)
    }

    @Test func M262_L1007057がlibrawと一致() throws {
        let image = try decode("L1007057.DNG")
        #expect(image.width == 5984)
        #expect(image.height == 4000)
        #expect(image.bitDepth == 14) // コンテナは16bit宣言だがストリームは14bit

        #expect(Array(image.samples[0 ..< 8]) == [129, 187, 143, 164, 161, 210, 138, 202])
        #expect(Array(image.samples[5984 ..< 5992]) == [178, 96, 189, 89, 207, 85, 182, 76])
        let center = 2000 * 5984 + 2992
        #expect(
            Array(image.samples[center ..< center + 8])
                == [7935, 10502, 8105, 10741, 8431, 11051, 8554, 11230])
        let tail = 4000 * 5984 - 8
        #expect(Array(image.samples[tail...]) == [1588, 683, 1342, 533, 1300, 634, 1528, 651])

        let sum = image.samples.reduce(UInt64(0)) { $0 + UInt64($1) }
        #expect(sum == 28_440_904_521)
        #expect(image.samples.max() == 15883)
    }
}
