import Foundation

/// Bayer raw → 表示色の共通パイプライン。
/// CFA位置別の正規化+WB LUT、cam→sRGB行列、sRGBガンマLUTを事前計算して保持する。
/// HalfSizeRenderer / FullDemosaicRenderer で共有
struct ColorPipeline {
    static let lutSize = 1 << 16

    /// CFA位置(2×2 row-major)ごとの 16bit値→(正規化+WB済み)Float LUT（4×65536）
    let positionLUTs: [Float]
    /// cam→sRGB 3×3（行優先）
    let matrix: [Float]
    /// 線形[0,1]→sRGB 8bit（4096分割+1）
    let gammaLUT: [UInt8]
    /// CFA位置→チャンネル（0=R, 1=G, 2=B）
    let channelOf: [Int]
    /// 2×2内の R / B の位置
    let rPosition: Int
    let bPosition: Int

    init(
        cfaPattern: [UInt8],
        blackLevels: [Double],
        whiteLevel: Int,
        asShotNeutral: [Double]?,
        colorMatrix2: [Double]?
    ) {
        let neutral = asShotNeutral ?? [1, 1, 1]

        // 想定外パターンはRGGB扱い
        var channels: [Int] = cfaPattern.count == 4 ? cfaPattern.map(Int.init) : [0, 1, 1, 2]
        if channels.sorted() != [0, 1, 1, 2] { channels = [0, 1, 1, 2] }
        channelOf = channels
        rPosition = channels.firstIndex(of: 0) ?? 0
        bPosition = channels.firstIndex(of: 2) ?? 3

        var luts = [Float](repeating: 0, count: 4 * Self.lutSize)
        for position in 0 ..< 4 {
            let black = blackLevels.count == 4 ? blackLevels[position] : 0
            let scale = 1.0 / (Double(whiteLevel) - black)
            let wb = 1.0 / max(neutral[channels[position]], 1e-6)
            let base = position * Self.lutSize
            for value in 0 ..< Self.lutSize {
                let linear = (Double(value) - black) * scale * wb
                luts[base + value] = Float(max(0, linear))
            }
        }
        positionLUTs = luts

        matrix = Self.cameraToSRGBMatrix(colorMatrix2: colorMatrix2).map(Float.init)

        var gamma = [UInt8](repeating: 0, count: 4097)
        for i in 0 ... 4096 {
            let v = Double(i) / 4096
            let srgb = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            gamma[i] = UInt8(min(255, max(0, srgb * 255 + 0.5)))
        }
        gammaLUT = gamma
    }

    /// dcraw と同じ流儀で cam→sRGB 行列を作る:
    /// ColorMatrix2(XYZ→cam) × (sRGB→XYZ) を行正規化して逆行列を取る。
    /// 行正規化により WB 済みのニュートラル (1,1,1) が sRGB の白に写る
    static func cameraToSRGBMatrix(colorMatrix2: [Double]?) -> [Double] {
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        guard let cm = colorMatrix2, cm.count == 9 else { return identity }

        // sRGB→XYZ (D65)
        let srgbToXYZ: [Double] = [
            0.4124564, 0.3575761, 0.1804375,
            0.2126729, 0.7151522, 0.0721750,
            0.0193339, 0.1191920, 0.9503041,
        ]
        var camRGB = [Double](repeating: 0, count: 9)
        for i in 0 ..< 3 {
            for j in 0 ..< 3 {
                for k in 0 ..< 3 {
                    camRGB[i * 3 + j] += cm[i * 3 + k] * srgbToXYZ[k * 3 + j]
                }
            }
        }
        for i in 0 ..< 3 {
            let sum = camRGB[i * 3] + camRGB[i * 3 + 1] + camRGB[i * 3 + 2]
            guard abs(sum) > 1e-9 else { return identity }
            for j in 0 ..< 3 { camRGB[i * 3 + j] /= sum }
        }
        return invert3x3(camRGB) ?? identity
    }

    static func invert3x3(_ m: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        return [
            (e * i - f * h) * inv, (c * h - b * i) * inv, (b * f - c * e) * inv,
            (f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv,
            (d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv,
        ]
    }
}
