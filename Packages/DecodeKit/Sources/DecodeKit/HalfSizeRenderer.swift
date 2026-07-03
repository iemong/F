import Foundation

/// 表示用 RGBA8888 画像（row-major、width×height×4 バイト、alpha=255）
public struct RGBA8Image: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
}

/// Bayer 2×2 → 1px のハーフサイズ縮約（デモザイク省略）。
/// 黒/白レベル正規化 → WB(AsShotNeutral) → ColorMatrix2逆行列由来のcam→sRGB → sRGBガンマ
public enum HalfSizeRenderer {
    public static func render(
        raw: RawImage,
        cfaPattern: [UInt8],
        blackLevels: [Double],
        whiteLevel: Int,
        asShotNeutral: [Double]?,
        colorMatrix2: [Double]?
    ) -> RGBA8Image {
        let halfWidth = raw.width / 2
        let halfHeight = raw.height / 2
        let neutral = asShotNeutral ?? [1, 1, 1]

        // CFA位置(2×2 row-major)→チャンネル。想定外パターンはRGGB扱い
        var channelOf: [Int] = cfaPattern.count == 4 ? cfaPattern.map(Int.init) : [0, 1, 1, 2]
        if channelOf.sorted() != [0, 1, 1, 2] { channelOf = [0, 1, 1, 2] }

        // CFA位置ごとの 16bit値→(正規化+WB済み)Float LUT
        let lutSize = 1 << 16
        var positionLUTs = [Float](repeating: 0, count: 4 * lutSize)
        for position in 0 ..< 4 {
            let black = blackLevels.count == 4 ? blackLevels[position] : 0
            let scale = 1.0 / (Double(whiteLevel) - black)
            let wb = 1.0 / max(neutral[channelOf[position]], 1e-6)
            let base = position * lutSize
            for value in 0 ..< lutSize {
                let linear = (Double(value) - black) * scale * wb
                positionLUTs[base + value] = Float(max(0, linear))
            }
        }

        let camToSRGB = Self.cameraToSRGBMatrix(colorMatrix2: colorMatrix2).map(Float.init)

        // 線形→sRGBガンマの LUT（4096分割）
        var gammaLUT = [UInt8](repeating: 0, count: 4097)
        for i in 0 ... 4096 {
            let v = Double(i) / 4096
            let srgb = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            gammaLUT[i] = UInt8(min(255, max(0, srgb * 255 + 0.5)))
        }

        var pixels = [UInt8](repeating: 255, count: halfWidth * halfHeight * 4)
        let rowStride = raw.width
        // 2×2 内の R/B の位置（channelOf は検証済みで必ず 0 と 2 を1つずつ含む）
        let rPosition = channelOf.firstIndex(of: 0) ?? 0
        let bPosition = channelOf.firstIndex(of: 2) ?? 3

        raw.samples.withUnsafeBufferPointer { srcBuffer in
            positionLUTs.withUnsafeBufferPointer { lutsBuffer in
                gammaLUT.withUnsafeBufferPointer { gammaBuffer in
                    pixels.withUnsafeMutableBufferPointer { dstBuffer in
                        nonisolated(unsafe) let src = srcBuffer.baseAddress!
                        nonisolated(unsafe) let luts = lutsBuffer.baseAddress!
                        nonisolated(unsafe) let gamma = gammaBuffer.baseAddress!
                        nonisolated(unsafe) let dst = dstBuffer.baseAddress!
                        let m0 = camToSRGB[0], m1 = camToSRGB[1], m2 = camToSRGB[2]
                        let m3 = camToSRGB[3], m4 = camToSRGB[4], m5 = camToSRGB[5]
                        let m6 = camToSRGB[6], m7 = camToSRGB[7], m8 = camToSRGB[8]

                        // 行単位で独立なので並列化できる（書き込み範囲は行ごとに素）
                        DispatchQueue.concurrentPerform(iterations: halfHeight) { y in
                            @inline(__always)
                            func pick(
                                _ position: Int,
                                _ v0: Float, _ v1: Float, _ v2: Float, _ v3: Float
                            ) -> Float {
                                switch position {
                                case 0: v0
                                case 1: v1
                                case 2: v2
                                default: v3
                                }
                            }
                            let row0 = (y * 2) * rowStride
                            let row1 = row0 + rowStride
                            var outIndex = y * halfWidth * 4
                            for x in 0 ..< halfWidth {
                                let col = x * 2
                                // 2×2 の4サンプルを位置別LUTで線形化
                                let v00 = luts[Int(src[row0 + col])]
                                let v01 = luts[lutSize + Int(src[row0 + col + 1])]
                                let v10 = luts[2 * lutSize + Int(src[row1 + col])]
                                let v11 = luts[3 * lutSize + Int(src[row1 + col + 1])]

                                // チャンネル集約（Gは残り2画素の平均）
                                let camR = pick(rPosition, v00, v01, v10, v11)
                                let camB = pick(bPosition, v00, v01, v10, v11)
                                let camG = (v00 + v01 + v10 + v11 - camR - camB) * 0.5

                                var r = m0 * camR + m1 * camG + m2 * camB
                                var g = m3 * camR + m4 * camG + m5 * camB
                                var b = m6 * camR + m7 * camG + m8 * camB
                                r = min(max(r, 0), 1)
                                g = min(max(g, 0), 1)
                                b = min(max(b, 0), 1)

                                dst[outIndex] = gamma[Int(r * 4096)]
                                dst[outIndex + 1] = gamma[Int(g * 4096)]
                                dst[outIndex + 2] = gamma[Int(b * 4096)]
                                // alpha は初期値 255 のまま
                                outIndex += 4
                            }
                        }
                    }
                }
            }
        }

        return RGBA8Image(width: halfWidth, height: halfHeight, pixels: pixels)
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
        // cam_rgb = cm × srgbToXYZ（sRGB→cam の応答）
        var camRGB = [Double](repeating: 0, count: 9)
        for i in 0 ..< 3 {
            for j in 0 ..< 3 {
                for k in 0 ..< 3 {
                    camRGB[i * 3 + j] += cm[i * 3 + k] * srgbToXYZ[k * 3 + j]
                }
            }
        }
        // 行正規化: cam の白応答を (1,1,1) に
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
