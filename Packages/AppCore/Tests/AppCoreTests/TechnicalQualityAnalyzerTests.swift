import Testing

@testable import AppCore

@Suite("技術品質解析")
struct TechnicalQualityAnalyzerTests {
    @Test func 平坦画像よりエッジ画像の鮮鋭度が高い() throws {
        let flat = [UInt8](repeating: 128, count: 16 * 16)
        let edges = (0 ..< 16 * 16).map { index in
            UInt8((index % 16) < 8 ? 0 : 255)
        }
        let flatMetrics = try #require(
            TechnicalQualityAnalyzer.analyze(luma: flat, width: 16, height: 16))
        let edgeMetrics = try #require(
            TechnicalQualityAnalyzer.analyze(luma: edges, width: 16, height: 16))
        #expect(edgeMetrics.sharpness > flatMetrics.sharpness)
        #expect(edgeMetrics.contrast > flatMetrics.contrast)
    }

    @Test func 白飛びと黒つぶれを画素比率で返す() throws {
        let pixels: [UInt8] = [0, 0, 128, 255, 0, 128, 255, 255, 128]
        let metrics = try #require(
            TechnicalQualityAnalyzer.analyze(luma: pixels, width: 3, height: 3))
        #expect(abs(metrics.highlightClipping - 1.0 / 3.0) < 0.001)
        #expect(abs(metrics.shadowClipping - 1.0 / 3.0) < 0.001)
    }

    @Test func 不正な輝度平面を拒否する() {
        #expect(TechnicalQualityAnalyzer.analyze(luma: [], width: 0, height: 0) == nil)
        #expect(TechnicalQualityAnalyzer.analyze(luma: [0], width: 3, height: 3) == nil)
    }
}
