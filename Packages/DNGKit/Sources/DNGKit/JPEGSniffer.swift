import Foundation

/// JPEG ヘッダの SOF マーカーからピクセル寸法を読む軽量パーサ。
/// MakerNotes 内プレビューなど、TIFF タグに寸法情報が無い JPEG に使う
public enum JPEGSniffer {
    public static func pixelSize(of data: Data) -> PixelSize? {
        // SOF はヘッダ近傍にあるので先頭 256KB だけ見れば十分
        let bytes = [UInt8](data.prefix(262_144))
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var i = 2
        while i + 3 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            // FF パディングをスキップ
            while i + 2 < bytes.count, bytes[i + 1] == 0xFF { i += 1 }
            let marker = bytes[i + 1]
            i += 2

            // スタンドアロンマーカー（長さフィールドなし）
            if marker == 0xD8 || (0xD0 ... 0xD7).contains(marker) { continue }
            // SOS/EOI 以降に SOF は現れない
            if marker == 0xDA || marker == 0xD9 { return nil }

            guard i + 1 < bytes.count else { return nil }
            let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            guard length >= 2 else { return nil }

            switch marker {
            case 0xC0 ... 0xC3, 0xC5 ... 0xC7, 0xC9 ... 0xCB, 0xCD ... 0xCF:
                guard i + 6 < bytes.count else { return nil }
                let height = Int(bytes[i + 3]) << 8 | Int(bytes[i + 4])
                let width = Int(bytes[i + 5]) << 8 | Int(bytes[i + 6])
                guard width > 0, height > 0 else { return nil }
                return PixelSize(width: width, height: height)
            default:
                i += length
            }
        }
        return nil
    }
}
