import Foundation

/// 境界チェック付きのエンディアン対応リーダー。オフセットは常にファイル先頭からの絶対位置
struct ByteReader {
    let data: Data
    let order: ByteOrder

    var count: Int { data.count }

    private func checkBounds(offset: Int, size: Int) throws {
        guard offset >= 0, size >= 0, offset <= data.count - size, data.count >= size else {
            throw DNGError.outOfBounds(offset: offset, size: size)
        }
    }

    func u8(at offset: Int) throws -> UInt8 {
        try checkBounds(offset: offset, size: 1)
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }
    }

    func u16(at offset: Int) throws -> UInt16 {
        try checkBounds(offset: offset, size: 2)
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        return order == .little ? UInt16(littleEndian: raw) : UInt16(bigEndian: raw)
    }

    func u32(at offset: Int) throws -> UInt32 {
        try checkBounds(offset: offset, size: 4)
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return order == .little ? UInt32(littleEndian: raw) : UInt32(bigEndian: raw)
    }

    func slice(at offset: Int, count: Int) throws -> Data {
        try checkBounds(offset: offset, size: count)
        return data.subdata(in: offset ..< offset + count)
    }

    func withFlippedOrder() -> ByteReader {
        ByteReader(data: data, order: order == .little ? .big : .little)
    }
}
