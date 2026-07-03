import Foundation
import Testing
import DNGKit

@Suite("不正入力")
struct InvalidInputTests {
    @Test func 空データ() {
        #expect(throws: DNGError.invalidHeader) {
            _ = try DNGFile(data: Data())
        }
    }

    @Test func 非TIFFデータ() {
        #expect(throws: DNGError.invalidHeader) {
            _ = try DNGFile(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]))
        }
    }

    @Test func マジックナンバー不一致() {
        // "II" だが 42 でない
        #expect(throws: DNGError.invalidHeader) {
            _ = try DNGFile(data: Data([0x49, 0x49, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]))
        }
    }

    @Test func IFDオフセットがファイル外() {
        // 正しい II*42 ヘッダだが IFD0 オフセットが範囲外
        var data = Data([0x49, 0x49, 0x2A, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0x00, 0x00]) // offset 65535
        #expect(throws: (any Error).self) {
            _ = try DNGFile(data: data)
        }
    }
}

@Suite("JPEGSniffer")
struct JPEGSnifferTests {
    @Test func SOF0から寸法を読める() {
        // FFD8 + APP0(最小) + SOF0(height=256, width=128)
        var jpeg = Data([0xFF, 0xD8])
        jpeg.append(contentsOf: [0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00]) // APP0 len=4
        jpeg.append(contentsOf: [
            0xFF, 0xC0, 0x00, 0x11, 0x08,
            0x01, 0x00, // height 256
            0x00, 0x80, // width 128
            0x03,
        ])
        #expect(JPEGSniffer.pixelSize(of: jpeg) == PixelSize(width: 128, height: 256))
    }

    @Test func 非JPEGはnil() {
        #expect(JPEGSniffer.pixelSize(of: Data([0x00, 0x01, 0x02, 0x03])) == nil)
        #expect(JPEGSniffer.pixelSize(of: Data()) == nil)
    }

    @Test func SOFの前にSOSが来たらnil() {
        var jpeg = Data([0xFF, 0xD8])
        jpeg.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02]) // いきなりSOS
        #expect(JPEGSniffer.pixelSize(of: jpeg) == nil)
    }
}
