import Foundation
import Testing
@testable import DecodeKit

/// 再現性のための線形合同法。テストデータ生成専用
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

@Suite("LJ92 ラウンドトリップ")
struct LJ92RoundTripTests {
    private func roundTrip(
        width: Int, height: Int, components: Int, precision: Int,
        predictor: Int, seed: UInt64
    ) throws {
        var rng = SeededRandom(seed: seed)
        let maxValue = (1 << precision) - 1
        let samples = (0 ..< width * height * components).map { _ in
            UInt16(rng.next(below: maxValue + 1))
        }
        let encoded = LJ92TestEncoder.encode(
            samples: samples, width: width, height: height,
            components: components, precision: precision, predictor: predictor)
        let decoded = try LJ92Decoder.decode(encoded)
        #expect(decoded.width == width * components)
        #expect(decoded.height == height)
        #expect(decoded.bitDepth == precision)
        #expect(decoded.samples == samples)
    }

    @Test(arguments: 1 ... 7)
    func 全予測器でランダムデータが一致する(predictor: Int) throws {
        try roundTrip(
            width: 16, height: 12, components: 1, precision: 14,
            predictor: predictor, seed: UInt64(predictor) * 7919)
    }

    @Test func カメラと同じ2成分インターリーブ() throws {
        try roundTrip(
            width: 32, height: 20, components: 2, precision: 14,
            predictor: 1, seed: 42)
    }

    @Test func 精度8bit() throws {
        try roundTrip(width: 8, height: 8, components: 1, precision: 8, predictor: 1, seed: 1)
    }

    @Test func 精度16bit() throws {
        try roundTrip(width: 8, height: 8, components: 2, precision: 16, predictor: 1, seed: 2)
    }

    @Test func 幅1ピクセル() throws {
        try roundTrip(width: 1, height: 16, components: 2, precision: 14, predictor: 4, seed: 3)
    }

    @Test func 高さ1ピクセル() throws {
        try roundTrip(width: 16, height: 1, components: 2, precision: 14, predictor: 1, seed: 4)
    }

    @Test func 一様データ_差分ゼロ連続() throws {
        let samples = [UInt16](repeating: 8000, count: 16 * 8 * 2)
        let encoded = LJ92TestEncoder.encode(
            samples: samples, width: 16, height: 8, components: 2, precision: 14, predictor: 1)
        let decoded = try LJ92Decoder.decode(encoded)
        #expect(decoded.samples == samples)
    }

    @Test func 最大振幅の交互データ_FFスタッフィング誘発() throws {
        // 0 ↔ 16383 の交互で大きな差分を連発させ、FFバイトとカテゴリ上限を踏む
        let width = 16, height = 8
        let samples = (0 ..< width * height).map { UInt16($0 % 2 == 0 ? 0 : 16383) }
        let encoded = LJ92TestEncoder.encode(
            samples: samples, width: width, height: height,
            components: 1, precision: 14, predictor: 1)
        let decoded = try LJ92Decoder.decode(encoded)
        #expect(decoded.samples == samples)
    }

    @Test func 不正データはエラー() {
        #expect(throws: (any Error).self) { _ = try LJ92Decoder.decode(Data()) }
        #expect(throws: (any Error).self) {
            _ = try LJ92Decoder.decode(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
        // ベースラインJPEG (SOF0) は拒否
        #expect(throws: (any Error).self) {
            var jpeg = Data([0xFF, 0xD8])
            jpeg.append(contentsOf: [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00])
            _ = try LJ92Decoder.decode(jpeg)
        }
    }
}
