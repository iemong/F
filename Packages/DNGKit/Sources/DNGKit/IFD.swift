import Foundation

enum TIFFTag {
    static let newSubfileType: UInt16 = 0x00FE
    static let imageWidth: UInt16 = 0x0100
    static let imageHeight: UInt16 = 0x0101
    static let bitsPerSample: UInt16 = 0x0102
    static let compression: UInt16 = 0x0103
    static let photometric: UInt16 = 0x0106
    static let model: UInt16 = 0x0110
    static let stripOffsets: UInt16 = 0x0111
    static let orientation: UInt16 = 0x0112
    static let stripByteCounts: UInt16 = 0x0117
    static let subIFDs: UInt16 = 0x014A
    static let jpegInterchangeFormat: UInt16 = 0x0201
    static let jpegInterchangeFormatLength: UInt16 = 0x0202
    static let cfaRepeatPatternDim: UInt16 = 0x828D
    static let cfaPattern: UInt16 = 0x828E
    static let exifIFD: UInt16 = 0x8769
    static let makerNote: UInt16 = 0x927C
    static let colorMatrix2: UInt16 = 0xC622
    static let asShotNeutral: UInt16 = 0xC628
    static let blackLevel: UInt16 = 0xC61A
    static let whiteLevel: UInt16 = 0xC61D
    /// Leica MakerNotes 内部IFDのプレビューJPEG
    static let leicaPreview: UInt16 = 0x0300

    /// PhotometricInterpretation: Color Filter Array
    static let photometricCFA: UInt32 = 32803
}

enum TIFFType {
    static func size(of type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1 // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: 2 // SHORT, SSHORT
        case 4, 9, 11, 13: 4 // LONG, SLONG, FLOAT, IFD
        case 5, 10, 12, 16, 17, 18: 8 // RATIONAL, SRATIONAL, DOUBLE, LONG8...
        default: 0
        }
    }
}

struct IFDEntry {
    let tag: UInt16
    let type: UInt16
    let count: Int
    /// 値が格納されているファイル絶対オフセット（インライン値ならエントリ内の位置）
    let valueOffset: Int

    /// BYTE/SHORT/LONG/IFD/UNDEFINED 型の値を符号なし整数として読む
    func uint(_ reader: ByteReader, index: Int = 0) throws -> UInt32? {
        guard index >= 0, index < count else { return nil }
        switch type {
        case 1, 7: return UInt32(try reader.u8(at: valueOffset + index))
        case 3: return UInt32(try reader.u16(at: valueOffset + index * 2))
        case 4, 13: return try reader.u32(at: valueOffset + index * 4)
        default: return nil
        }
    }

    func uints(_ reader: ByteReader) throws -> [UInt32] {
        var values: [UInt32] = []
        values.reserveCapacity(count)
        for i in 0 ..< count {
            guard let v = try uint(reader, index: i) else { break }
            values.append(v)
        }
        return values
    }

    /// RATIONAL/SRATIONAL/整数型の値を Double として読む
    func double(_ reader: ByteReader, index: Int = 0) throws -> Double? {
        guard index >= 0, index < count else { return nil }
        switch type {
        case 5: // RATIONAL
            let num = try reader.u32(at: valueOffset + index * 8)
            let den = try reader.u32(at: valueOffset + index * 8 + 4)
            guard den != 0 else { return nil }
            return Double(num) / Double(den)
        case 10: // SRATIONAL
            let num = Int32(bitPattern: try reader.u32(at: valueOffset + index * 8))
            let den = Int32(bitPattern: try reader.u32(at: valueOffset + index * 8 + 4))
            guard den != 0 else { return nil }
            return Double(num) / Double(den)
        case 8: // SSHORT
            return Double(Int16(bitPattern: try reader.u16(at: valueOffset + index * 2)))
        case 9: // SLONG
            return Double(Int32(bitPattern: try reader.u32(at: valueOffset + index * 4)))
        default:
            return try uint(reader, index: index).map(Double.init)
        }
    }

    func doubles(_ reader: ByteReader) throws -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(count)
        for i in 0 ..< count {
            guard let v = try double(reader, index: i) else { break }
            values.append(v)
        }
        return values
    }

    func string(_ reader: ByteReader) throws -> String? {
        guard type == 2, count > 0 else { return nil }
        let raw = try reader.slice(at: valueOffset, count: count)
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}

struct IFD {
    private(set) var entries: [UInt16: IFDEntry] = [:]
    private(set) var nextIFDOffset: Int = 0

    subscript(tag: UInt16) -> IFDEntry? { entries[tag] }

    /// 通常のTIFF IFD（エントリ数 u16 / エントリ 12byte / 次IFDオフセット u32）を読む。
    /// hasNextOffset=false は末尾の次IFDオフセットを持たない変則IFD（Leica MakerNotes内部）用
    static func parse(_ reader: ByteReader, at offset: Int, hasNextOffset: Bool = true) throws -> IFD {
        let count = Int(try reader.u16(at: offset))
        guard count > 0, count < 4096 else {
            throw DNGError.malformed("IFD entry count \(count) at offset \(offset)")
        }
        var ifd = IFD()
        var pos = offset + 2
        for _ in 0 ..< count {
            let tag = try reader.u16(at: pos)
            let type = try reader.u16(at: pos + 2)
            let valueCount = Int(try reader.u32(at: pos + 4))
            let byteSize = TIFFType.size(of: type) * valueCount
            let valueOffset: Int =
                if byteSize <= 4 {
                    pos + 8
                } else {
                    Int(try reader.u32(at: pos + 8))
                }
            ifd.entries[tag] = IFDEntry(
                tag: tag, type: type, count: valueCount, valueOffset: valueOffset)
            pos += 12
        }
        if hasNextOffset {
            ifd.nextIFDOffset = Int(try reader.u32(at: pos))
        }
        return ifd
    }
}
