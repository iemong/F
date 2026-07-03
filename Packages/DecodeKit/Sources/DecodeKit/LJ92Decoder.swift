import Foundation

/// LJ92（lossless JPEG, SOF3）のデコード結果。
/// 2成分インターリーブは水平方向に展開済み（width = SOF幅 × 成分数）
public struct RawImage: Sendable {
    public let width: Int
    public let height: Int
    /// SOF3 の precision（有効ビット数）。Q3/M262 とも実測14
    public let bitDepth: Int
    /// row-major、width×height 要素
    public let samples: [UInt16]

    public init(width: Int, height: Int, bitDepth: Int, samples: [UInt16]) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.samples = samples
    }
}

public enum LJ92Error: Error, Equatable {
    case notLosslessJPEG
    case truncated
    case malformed(String)
    case unsupported(String)
}

/// T.81 lossless プロセス(SOF3)のデコーダ。
/// 対応範囲: 1〜4成分・サンプリング1x1・Al=0・リスタートマーカーなし
/// （M262/Q3 の実測ストリーム構成。仕様全域はスコープ外）
public enum LJ92Decoder {
    public static func decode(_ data: Data) throws -> RawImage {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                throw LJ92Error.truncated
            }
            return try decode(bytes: base, count: buffer.count)
        }
    }

    // MARK: - マーカーパース

    private struct Frame {
        var precision = 0
        var height = 0
        var width = 0
        var componentIDs: [Int] = []
    }

    private static func decode(bytes: UnsafePointer<UInt8>, count: Int) throws -> RawImage {
        guard count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw LJ92Error.notLosslessJPEG
        }

        var tables = [HuffmanTable?](repeating: nil, count: 4)
        var frame: Frame?
        var pos = 2

        while pos + 4 <= count {
            guard bytes[pos] == 0xFF else {
                throw LJ92Error.malformed("marker expected at \(pos)")
            }
            let marker = bytes[pos + 1]
            pos += 2
            if marker == 0xD8 || (0xD0 ... 0xD7).contains(marker) { continue }
            if marker == 0xD9 { break }

            guard pos + 2 <= count else { throw LJ92Error.truncated }
            let length = Int(bytes[pos]) << 8 | Int(bytes[pos + 1])
            guard length >= 2, pos + length <= count else { throw LJ92Error.truncated }
            let body = pos + 2
            let bodyLength = length - 2

            switch marker {
            case 0xC3:
                frame = try parseSOF3(bytes: bytes + body, length: bodyLength)
            case 0xC0, 0xC1, 0xC2, 0xC5 ... 0xC7, 0xC9 ... 0xCB, 0xCD ... 0xCF:
                throw LJ92Error.notLosslessJPEG
            case 0xC4:
                try parseDHT(bytes: bytes + body, length: bodyLength, into: &tables)
            case 0xDD:
                throw LJ92Error.unsupported("restart interval")
            case 0xDA:
                guard let frame else { throw LJ92Error.malformed("SOS before SOF3") }
                return try decodeScan(
                    bytes: bytes, count: count, sosBody: body, sosLength: bodyLength,
                    frame: frame, tables: tables)
            default:
                break // APPn / COM は読み飛ばす
            }
            pos += length
        }
        throw LJ92Error.malformed("no scan data")
    }

    private static func parseSOF3(bytes: UnsafePointer<UInt8>, length: Int) throws -> Frame {
        guard length >= 6 else { throw LJ92Error.truncated }
        var frame = Frame()
        frame.precision = Int(bytes[0])
        frame.height = Int(bytes[1]) << 8 | Int(bytes[2])
        frame.width = Int(bytes[3]) << 8 | Int(bytes[4])
        let componentCount = Int(bytes[5])
        guard (2 ... 16).contains(frame.precision) else {
            throw LJ92Error.unsupported("precision \(frame.precision)")
        }
        guard (1 ... 4).contains(componentCount), length >= 6 + componentCount * 3 else {
            throw LJ92Error.unsupported("\(componentCount) components")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw LJ92Error.malformed("empty frame")
        }
        for c in 0 ..< componentCount {
            let id = Int(bytes[6 + c * 3])
            let sampling = bytes[7 + c * 3]
            guard sampling == 0x11 else {
                throw LJ92Error.unsupported("sampling factor \(sampling)")
            }
            frame.componentIDs.append(id)
        }
        return frame
    }

    private static func parseDHT(
        bytes: UnsafePointer<UInt8>, length: Int, into tables: inout [HuffmanTable?]
    ) throws {
        var pos = 0
        while pos < length {
            guard pos + 17 <= length else { throw LJ92Error.truncated }
            let tcTh = bytes[pos]
            let tableID = Int(tcTh & 0x0F)
            guard tableID < 4 else { throw LJ92Error.malformed("DHT table id") }
            var counts = [Int](repeating: 0, count: 16)
            var total = 0
            for i in 0 ..< 16 {
                counts[i] = Int(bytes[pos + 1 + i])
                total += counts[i]
            }
            guard total > 0, total <= 256, pos + 17 + total <= length else {
                throw LJ92Error.malformed("DHT values")
            }
            var values = [UInt8](repeating: 0, count: total)
            for i in 0 ..< total { values[i] = bytes[pos + 17 + i] }
            tables[tableID] = try HuffmanTable(counts: counts, values: values)
            pos += 17 + total
        }
    }

    // MARK: - Huffman

    private struct HuffmanTable {
        /// 16bit 先読み → (符号長 << 8 | ssss)。0 = 不正符号
        var lut: [UInt16]

        init(counts: [Int], values: [UInt8]) throws {
            lut = [UInt16](repeating: 0, count: 65536)
            var code = 0
            var k = 0
            for lengthIndex in 0 ..< 16 {
                let bitLength = lengthIndex + 1
                for _ in 0 ..< counts[lengthIndex] {
                    guard code < (1 << bitLength) else {
                        throw LJ92Error.malformed("overfull huffman table")
                    }
                    let value = values[k]
                    guard value <= 16 else {
                        throw LJ92Error.malformed("ssss > 16")
                    }
                    k += 1
                    let shift = 16 - bitLength
                    let start = code << shift
                    let entry = UInt16(bitLength) << 8 | UInt16(value)
                    for i in start ..< start + (1 << shift) { lut[i] = entry }
                    code += 1
                }
                code <<= 1
            }
        }
    }

    // MARK: - エントロピーデコード

    private struct BitReader {
        let bytes: UnsafePointer<UInt8>
        let count: Int
        var pos: Int
        var bitBuffer: UInt64 = 0
        var bitCount: Int = 0

        init(bytes: UnsafePointer<UInt8>, count: Int, start: Int) {
            self.bytes = bytes
            self.count = count
            self.pos = start
        }

        /// 32bit 以上溜まるまで補充する。
        /// 高速パス: 0xFF を含まない 4 バイトを一括で詰める（スタッフィング検査不要）
        @inline(__always)
        mutating func ensure32() {
            while bitCount <= 32 {
                if pos + 4 <= count {
                    let chunk = UnsafeRawPointer(bytes + pos)
                        .loadUnaligned(as: UInt32.self).bigEndian
                    // 0xFF バイト検出（~chunk のゼロバイト検出トリック）
                    let inverted = ~chunk
                    if (inverted &- 0x0101_0101) & ~inverted & 0x8080_8080 == 0 {
                        bitBuffer = (bitBuffer << 32) | UInt64(chunk)
                        bitCount += 32
                        pos += 4
                        continue
                    }
                }
                // スローパス: 1バイトずつスタッフィング処理
                var byte: UInt64 = 0
                if pos < count {
                    let b = bytes[pos]
                    if b == 0xFF {
                        if pos + 1 < count, bytes[pos + 1] == 0x00 {
                            pos += 2 // スタッフィング解除
                            byte = 0xFF
                        } else {
                            // マーカー到達 = データ終端。ゼロ詰め
                            byte = 0
                            pos = count
                        }
                    } else {
                        pos += 1
                        byte = UInt64(b)
                    }
                } // ストリーム終端後もゼロ詰め（サンプル数で停止するため無限には読まない）
                bitBuffer = (bitBuffer << 8) | byte
                bitCount += 8
            }
        }

        /// ensure32 済み前提。先読み16bit
        @inline(__always)
        func peek16() -> Int {
            Int((bitBuffer >> UInt64(bitCount - 16)) & 0xFFFF)
        }

        /// ensure32 済み前提。n ≤ 16 bit 取り出し（peek16 の consume 後でも残量保証あり）
        @inline(__always)
        mutating func take(_ n: Int) -> Int {
            let value = Int((bitBuffer >> UInt64(bitCount - n)) & UInt64((1 << n) - 1))
            bitCount -= n
            return value
        }

        /// Huffman符号+追加ビットを読んで差分値を返す。
        /// 1サンプル = 最大 16+16bit なので ensure32 一回で残量保証が成立する
        @inline(__always)
        mutating func decodeDiff(lut: UnsafePointer<UInt16>, lutBase: Int) throws -> Int {
            ensure32()
            let entry = lut[lutBase | peek16()]
            let length = Int(entry >> 8)
            guard length != 0 else { throw LJ92Error.malformed("invalid huffman code") }
            bitCount -= length
            let ssss = Int(entry & 0xFF)
            if ssss == 0 { return 0 }
            if ssss == 16 { return 32768 }
            let value = take(ssss)
            return value < (1 << (ssss - 1)) ? value - (1 << ssss) + 1 : value
        }
    }

    private static func decodeScan(
        bytes: UnsafePointer<UInt8>, count: Int, sosBody: Int, sosLength: Int,
        frame: Frame, tables: [HuffmanTable?]
    ) throws -> RawImage {
        let componentCount = frame.componentIDs.count
        guard sosLength >= 4 + componentCount * 2 else { throw LJ92Error.truncated }
        guard Int(bytes[sosBody]) == componentCount else {
            throw LJ92Error.unsupported("scan component count mismatch")
        }

        // 成分ごとのHuffmanテーブルを解決（SOS の Td）
        var componentTableIDs: [Int] = []
        for c in 0 ..< componentCount {
            let tableID = Int(bytes[sosBody + 2 + c * 2] >> 4)
            guard tableID < 4, tables[tableID] != nil else {
                throw LJ92Error.malformed("missing huffman table \(tableID)")
            }
            componentTableIDs.append(tableID)
        }
        let predictor = Int(bytes[sosBody + 1 + componentCount * 2]) // Ss
        let ahAl = bytes[sosBody + 3 + componentCount * 2]
        guard (1 ... 7).contains(predictor) else {
            throw LJ92Error.unsupported("predictor \(predictor)")
        }
        guard ahAl & 0x0F == 0 else {
            throw LJ92Error.unsupported("point transform")
        }

        // 実機ストリームは全成分が同一テーブルを共有する。重複を排除して
        // LUT のキャッシュフットプリントを最小化（1テーブル=128KB）
        var uniqueIDs: [Int] = []
        var componentLUTBases = [Int](repeating: 0, count: componentCount)
        for (c, id) in componentTableIDs.enumerated() {
            if let existing = uniqueIDs.firstIndex(of: id) {
                componentLUTBases[c] = existing << 16
            } else {
                componentLUTBases[c] = uniqueIDs.count << 16
                uniqueIDs.append(id)
            }
        }
        var combinedLUT = [UInt16]()
        combinedLUT.reserveCapacity(65536 * uniqueIDs.count)
        for id in uniqueIDs { combinedLUT.append(contentsOf: tables[id]!.lut) }
        let sharedTable = uniqueIDs.count == 1

        let rowSamples = frame.width * componentCount
        let totalSamples = rowSamples * frame.height
        let defaultValue = 1 << (frame.precision - 1)
        var output = [UInt16](repeating: 0, count: totalSamples)

        var reader = BitReader(bytes: bytes, count: count, start: sosBody + sosLength)

        try output.withUnsafeMutableBufferPointer { out in
            try combinedLUT.withUnsafeBufferPointer { lutBuffer in
                guard let lut = lutBuffer.baseAddress, let outBase = out.baseAddress else {
                    throw LJ92Error.malformed("empty buffers")
                }
                try decodeEntropy(
                    reader: &reader, lut: lut, out: outBase,
                    rowSamples: rowSamples, height: frame.height,
                    componentCount: componentCount, predictor: predictor,
                    defaultValue: defaultValue,
                    lutBases: componentLUTBases, sharedTable: sharedTable)
            }
        }

        return RawImage(
            width: rowSamples, height: frame.height,
            bitDepth: frame.precision, samples: output)
    }

    /// エントロピーデコードの本体。クロージャキャプチャを避けるため
    /// すべて引数渡し（reader は inout）にしてホットループをフラットに保つ
    private static func decodeEntropy(
        reader: inout BitReader,
        lut: UnsafePointer<UInt16>,
        out: UnsafeMutablePointer<UInt16>,
        rowSamples: Int,
        height: Int,
        componentCount: Int,
        predictor: Int,
        defaultValue: Int,
        lutBases: [Int],
        sharedTable: Bool
    ) throws {
        // 先頭行: 最初のMCUは 2^(P-1)、以降は同成分の左隣(Ra)
        var component = 0
        for i in 0 ..< rowSamples {
            let px = i < componentCount ? defaultValue : Int(out[i - componentCount])
            let diff = try reader.decodeDiff(lut: lut, lutBase: lutBases[component])
            out[i] = UInt16(truncatingIfNeeded: px &+ diff)
            component += 1
            if component == componentCount { component = 0 }
        }

        for y in 1 ..< height {
            let rowBase = y * rowSamples
            // 行頭MCUは真上(Rb)
            for c in 0 ..< componentCount {
                let idx = rowBase + c
                let diff = try reader.decodeDiff(lut: lut, lutBase: lutBases[c])
                out[idx] = UInt16(truncatingIfNeeded: Int(out[idx - rowSamples]) &+ diff)
            }

            if predictor == 1 && sharedTable {
                // 両機種の実測パス（予測器Ra・共有テーブル）を完全特化:
                // 成分カウンタもLUTベースオフセットも不要
                for i in componentCount ..< rowSamples {
                    let idx = rowBase + i
                    let diff = try reader.decodeDiff(lut: lut, lutBase: 0)
                    out[idx] = UInt16(
                        truncatingIfNeeded: Int(out[idx - componentCount]) &+ diff)
                }
            } else if predictor == 1 {
                var component = 0
                for i in componentCount ..< rowSamples {
                    let idx = rowBase + i
                    let diff = try reader.decodeDiff(lut: lut, lutBase: lutBases[component])
                    out[idx] = UInt16(
                        truncatingIfNeeded: Int(out[idx - componentCount]) &+ diff)
                    component += 1
                    if component == componentCount { component = 0 }
                }
            } else {
                var component = 0
                for i in componentCount ..< rowSamples {
                    let idx = rowBase + i
                    let ra = Int(out[idx - componentCount])
                    let rb = Int(out[idx - rowSamples])
                    let px: Int
                    switch predictor {
                    case 2: px = rb
                    case 3: px = Int(out[idx - rowSamples - componentCount])
                    case 4: px = ra &+ rb &- Int(out[idx - rowSamples - componentCount])
                    case 5:
                        px = ra &+ ((rb &- Int(out[idx - rowSamples - componentCount])) >> 1)
                    case 6:
                        px = rb &+ ((ra &- Int(out[idx - rowSamples - componentCount])) >> 1)
                    default: px = (ra &+ rb) >> 1
                    }
                    let diff = try reader.decodeDiff(lut: lut, lutBase: lutBases[component])
                    out[idx] = UInt16(truncatingIfNeeded: px &+ diff)
                    component += 1
                    if component == componentCount { component = 0 }
                }
            }
        }
    }
}
