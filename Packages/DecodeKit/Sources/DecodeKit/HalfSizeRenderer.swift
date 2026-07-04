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
        let pipeline = ColorPipeline(
            cfaPattern: cfaPattern, blackLevels: blackLevels, whiteLevel: whiteLevel,
            asShotNeutral: asShotNeutral, colorMatrix2: colorMatrix2)
        let halfWidth = raw.width / 2
        let halfHeight = raw.height / 2
        let lutSize = ColorPipeline.lutSize

        var pixels = [UInt8](repeating: 255, count: halfWidth * halfHeight * 4)
        let rowStride = raw.width
        let rPosition = pipeline.rPosition
        let bPosition = pipeline.bPosition

        raw.samples.withUnsafeBufferPointer { srcBuffer in
            pipeline.positionLUTs.withUnsafeBufferPointer { lutsBuffer in
                pipeline.gammaLUT.withUnsafeBufferPointer { gammaBuffer in
                    pixels.withUnsafeMutableBufferPointer { dstBuffer in
                        nonisolated(unsafe) let src = srcBuffer.baseAddress!
                        nonisolated(unsafe) let luts = lutsBuffer.baseAddress!
                        nonisolated(unsafe) let gamma = gammaBuffer.baseAddress!
                        nonisolated(unsafe) let dst = dstBuffer.baseAddress!
                        let m0 = pipeline.matrix[0], m1 = pipeline.matrix[1], m2 = pipeline.matrix[2]
                        let m3 = pipeline.matrix[3], m4 = pipeline.matrix[4], m5 = pipeline.matrix[5]
                        let m6 = pipeline.matrix[6], m7 = pipeline.matrix[7], m8 = pipeline.matrix[8]

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
}
