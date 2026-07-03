import Foundation
@testable import DecodeKit

/// テスト専用の最小 LJ92 エンコーダ。デコーダのラウンドトリップ検証に使う。
/// T.81 の lossless プロセス(SOF3)を、単一Huffmanテーブル・Al=0 で書き出す
enum LJ92TestEncoder {
    /// ssss カテゴリ 0...16 に割り当てる符号長（非減少 → HUFFVAL は 0...16 の昇順）
    static let codeLengths: [Int] = [2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13]

    private static func canonicalCodes() -> [(code: Int, length: Int)] {
        var codes = [(code: Int, length: Int)](repeating: (0, 0), count: codeLengths.count)
        var code = 0
        var symbol = 0
        for length in 1 ... 16 {
            while symbol < codeLengths.count, codeLengths[symbol] == length {
                codes[symbol] = (code, length)
                code += 1
                symbol += 1
            }
            code <<= 1
        }
        return codes
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        private var acc: UInt32 = 0
        private var bitCount = 0

        mutating func put(_ value: Int, bits: Int) {
            guard bits > 0 else { return }
            acc = (acc << UInt32(bits)) | UInt32(value & ((1 << bits) - 1))
            bitCount += bits
            while bitCount >= 8 {
                let byte = UInt8((acc >> UInt32(bitCount - 8)) & 0xFF)
                bytes.append(byte)
                if byte == 0xFF { bytes.append(0x00) } // スタッフィング
                bitCount -= 8
            }
        }

        mutating func flush() {
            if bitCount > 0 {
                // 1詰めでバイト境界に揃える（T.81 準拠）
                let pad = 8 - bitCount
                put((1 << pad) - 1, bits: pad)
            }
        }
    }

    /// samples: インターリーブ済み row-major（幅 = width×components）
    static func encode(
        samples: [UInt16], width: Int, height: Int, components: Int,
        precision: Int, predictor: Int
    ) -> Data {
        precondition(samples.count == width * height * components)
        let codes = canonicalCodes()
        let rowSamples = width * components
        let defaultValue = 1 << (precision - 1)

        var out = Data([0xFF, 0xD8]) // SOI

        // DHT (table 0)
        var bits = [UInt8](repeating: 0, count: 16)
        for length in codeLengths { bits[length - 1] += 1 }
        var dht = Data([0xFF, 0xC4])
        let dhtLen = 2 + 1 + 16 + codeLengths.count
        dht.append(contentsOf: [UInt8(dhtLen >> 8), UInt8(dhtLen & 0xFF), 0x00])
        dht.append(contentsOf: bits)
        dht.append(contentsOf: (0 ... 16).map(UInt8.init))
        out.append(dht)

        // SOF3
        var sof = Data([0xFF, 0xC3])
        let sofLen = 8 + 3 * components
        sof.append(contentsOf: [
            UInt8(sofLen >> 8), UInt8(sofLen & 0xFF), UInt8(precision),
            UInt8(height >> 8), UInt8(height & 0xFF),
            UInt8(width >> 8), UInt8(width & 0xFF),
            UInt8(components),
        ])
        for c in 0 ..< components {
            sof.append(contentsOf: [UInt8(c + 1), 0x11, 0x00])
        }
        out.append(sof)

        // SOS
        var sos = Data([0xFF, 0xDA])
        let sosLen = 6 + 2 * components
        sos.append(contentsOf: [UInt8(sosLen >> 8), UInt8(sosLen & 0xFF), UInt8(components)])
        for c in 0 ..< components {
            sos.append(contentsOf: [UInt8(c + 1), 0x00])
        }
        sos.append(contentsOf: [UInt8(predictor), 0x00, 0x00])
        out.append(sos)

        // エントロピーデータ（デコーダと同じ予測規則）
        var writer = BitWriter()
        for y in 0 ..< height {
            for i in 0 ..< rowSamples {
                let idx = y * rowSamples + i
                let px: Int
                if y == 0 {
                    px = i < components ? defaultValue : Int(samples[idx - components])
                } else if i < components {
                    px = Int(samples[idx - rowSamples])
                } else {
                    let ra = Int(samples[idx - components])
                    let rb = Int(samples[idx - rowSamples])
                    let rc = Int(samples[idx - rowSamples - components])
                    switch predictor {
                    case 1: px = ra
                    case 2: px = rb
                    case 3: px = rc
                    case 4: px = ra + rb - rc
                    case 5: px = ra + ((rb - rc) >> 1)
                    case 6: px = rb + ((ra - rc) >> 1)
                    case 7: px = (ra + rb) >> 1
                    default: fatalError("bad predictor")
                    }
                }
                var diff = (Int(samples[idx]) - px) & 0xFFFF
                if diff >= 0x8000 { diff -= 0x10000 } // [-32768, 32767]

                if diff == 0 {
                    writer.put(codes[0].code, bits: codes[0].length)
                } else if diff == -32768 {
                    // mod 2^16 では +32768 と等価 → カテゴリ16（追加ビットなし）
                    writer.put(codes[16].code, bits: codes[16].length)
                } else {
                    let magnitude = diff < 0 ? -diff : diff
                    let ssss = Int.bitWidth - magnitude.leadingZeroBitCount
                    writer.put(codes[ssss].code, bits: codes[ssss].length)
                    let value = diff < 0 ? diff + (1 << ssss) - 1 : diff
                    writer.put(value, bits: ssss)
                }
            }
        }
        writer.flush()
        out.append(contentsOf: writer.bytes)
        out.append(contentsOf: [0xFF, 0xD9]) // EOI
        return out
    }
}
