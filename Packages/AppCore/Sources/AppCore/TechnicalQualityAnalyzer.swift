import Foundation

public struct QualityMetrics: Codable, Equatable, Sendable {
    /// 0...1。ラプラシアン分散を正規化した相対的な鮮鋭度。
    public let sharpness: Double
    /// 0...1。輝度250以上の画素比率。
    public let highlightClipping: Double
    /// 0...1。輝度5以下の画素比率。
    public let shadowClipping: Double
    /// 0...1。輝度標準偏差を正規化したコントラスト。
    public let contrast: Double
    /// 0...100。上記指標から作る技術的な参考スコア。
    public let overallScore: Double

    public init(
        sharpness: Double, highlightClipping: Double, shadowClipping: Double,
        contrast: Double, overallScore: Double
    ) {
        self.sharpness = sharpness
        self.highlightClipping = highlightClipping
        self.shadowClipping = shadowClipping
        self.contrast = contrast
        self.overallScore = overallScore
    }
}

public enum TechnicalQualityAnalyzer {
    /// 8bit輝度平面だけを使う軽量解析。元画像の変更や大規模モデルは不要。
    public static func analyze(
        luma: [UInt8], width: Int, height: Int
    ) -> QualityMetrics? {
        guard width > 2, height > 2, luma.count == width * height else { return nil }
        let count = Double(luma.count)
        let values = luma.map(Double.init)
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let contrast = min(1, sqrt(variance) / 64)
        let highlights = Double(luma.count(where: { $0 >= 250 })) / count
        let shadows = Double(luma.count(where: { $0 <= 5 })) / count

        var laplacianEnergy = 0.0
        var laplacianCount = 0
        for y in 1 ..< (height - 1) {
            for x in 1 ..< (width - 1) {
                let index = y * width + x
                let center = Double(luma[index]) * 4
                let neighbors = Double(luma[index - 1]) + Double(luma[index + 1])
                    + Double(luma[index - width]) + Double(luma[index + width])
                let laplacian = center - neighbors
                laplacianEnergy += laplacian * laplacian
                laplacianCount += 1
            }
        }
        let rawSharpness = laplacianEnergy / Double(max(1, laplacianCount))
        let sharpness = min(1, rawSharpness / 8_000)
        let clippingPenalty = min(1, (highlights + shadows) * 4)
        let overall = 100 * max(
            0, 0.55 * sharpness + 0.25 * contrast + 0.20 * (1 - clippingPenalty))
        return QualityMetrics(
            sharpness: sharpness,
            highlightClipping: highlights,
            shadowClipping: shadows,
            contrast: contrast,
            overallScore: overall)
    }
}
