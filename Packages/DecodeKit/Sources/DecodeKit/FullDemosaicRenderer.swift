import Foundation

/// フル解像度の bilinear デモザイク。100%等倍でのピント確認用（遅延実行前提）。
/// - G は R/B 画素上で上下左右4点平均（Bayerの性質上、十字近傍は必ずG）
/// - R/B は G 画素上で水平または垂直2点平均、対向色画素上で対角4点平均
/// 色処理（正規化/WB/行列/ガンマ）は HalfSizeRenderer と共通の ColorPipeline
public enum FullDemosaicRenderer {
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
        let width = raw.width
        let height = raw.height

        // CFA位置(0-3)ごとの事前計算:
        // 自位置のチャンネル / G位置での水平隣接チャンネルがRか
        let channelOf = pipeline.channelOf
        var horizontalIsR = [Bool](repeating: false, count: 4)
        for position in 0 ..< 4 where channelOf[position] == 1 {
            let rowBase = position & 2
            let horizontalNeighbor = rowBase | (1 - (position & 1))
            horizontalIsR[position] = channelOf[horizontalNeighbor] == 0
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)

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
                        let ch0 = channelOf[0], ch1 = channelOf[1]
                        let ch2 = channelOf[2], ch3 = channelOf[3]
                        let hIsR0 = horizontalIsR[0], hIsR1 = horizontalIsR[1]
                        let hIsR2 = horizontalIsR[2], hIsR3 = horizontalIsR[3]

                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            // 近傍座標は端でクランプ（端1pxの色は近似でよい）
                            @inline(__always)
                            func linear(_ xx: Int, _ yy: Int) -> Float {
                                let position = ((yy & 1) << 1) | (xx & 1)
                                return luts[(position << 16) | Int(src[yy * width + xx])]
                            }
                            let up = y > 0 ? y - 1 : 1
                            let down = y < height - 1 ? y + 1 : height - 2
                            var outIndex = y * width * 4
                            for x in 0 ..< width {
                                let left = x > 0 ? x - 1 : 1
                                let right = x < width - 1 ? x + 1 : width - 2
                                let position = ((y & 1) << 1) | (x & 1)
                                let channel =
                                    position == 0 ? ch0 : position == 1 ? ch1 : position == 2 ? ch2 : ch3
                                let own = linear(x, y)

                                var camR: Float
                                var camG: Float
                                var camB: Float
                                if channel == 1 {
                                    camG = own
                                    let horizontal = (linear(left, y) + linear(right, y)) * 0.5
                                    let vertical = (linear(x, up) + linear(x, down)) * 0.5
                                    let hIsR =
                                        position == 0 ? hIsR0 : position == 1 ? hIsR1 : position == 2 ? hIsR2 : hIsR3
                                    if hIsR {
                                        camR = horizontal
                                        camB = vertical
                                    } else {
                                        camR = vertical
                                        camB = horizontal
                                    }
                                } else {
                                    camG =
                                        (linear(left, y) + linear(right, y)
                                            + linear(x, up) + linear(x, down)) * 0.25
                                    let diagonal =
                                        (linear(left, up) + linear(right, up)
                                            + linear(left, down) + linear(right, down)) * 0.25
                                    if channel == 0 {
                                        camR = own
                                        camB = diagonal
                                    } else {
                                        camB = own
                                        camR = diagonal
                                    }
                                }

                                var r = m0 * camR + m1 * camG + m2 * camB
                                var g = m3 * camR + m4 * camG + m5 * camB
                                var b = m6 * camR + m7 * camG + m8 * camB
                                r = min(max(r, 0), 1)
                                g = min(max(g, 0), 1)
                                b = min(max(b, 0), 1)

                                dst[outIndex] = gamma[Int(r * 4096)]
                                dst[outIndex + 1] = gamma[Int(g * 4096)]
                                dst[outIndex + 2] = gamma[Int(b * 4096)]
                                outIndex += 4
                            }
                        }
                    }
                }
            }
        }

        return RGBA8Image(width: width, height: height, pixels: pixels)
    }
}
