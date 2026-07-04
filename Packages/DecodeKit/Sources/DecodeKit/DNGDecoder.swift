import DNGKit
import Foundation
import os

public enum DecodeError: Error, Equatable {
    case noRawData
    case unsupportedLayout(String)
}

/// DNGFile → 表示用画像のフルパイプライン。os_signpost で各段を計測する
public enum DNGDecoder {
    private static let signposter = OSSignposter(
        subsystem: "LeicaSelect.DecodeKit", category: "decode")

    /// raw を LJ92 デコードして 2×2→1px のハーフサイズ RGBA8 を返す。
    /// キー送り時のフィット表示用（M262 で必須のパス）
    public static func halfSizeImage(from file: DNGFile) throws -> RGBA8Image {
        guard let rawInfo = file.raw else { throw DecodeError.noRawData }
        guard rawInfo.compression == 7 else {
            throw DecodeError.unsupportedLayout("compression \(rawInfo.compression)")
        }

        let readState = signposter.beginInterval("read")
        guard let data = file.rawDataContiguous() else { throw DecodeError.noRawData }
        signposter.endInterval("read", readState)

        let decodeState = signposter.beginInterval("lj92")
        let raw = try LJ92Decoder.decode(data)
        signposter.endInterval("lj92", decodeState)

        guard raw.width == rawInfo.pixelSize.width, raw.height == rawInfo.pixelSize.height
        else {
            throw DecodeError.unsupportedLayout(
                "decoded \(raw.width)x\(raw.height) != tag \(rawInfo.pixelSize)")
        }

        let renderState = signposter.beginInterval("halfsize")
        let image = HalfSizeRenderer.render(
            raw: raw,
            cfaPattern: rawInfo.cfaPattern,
            blackLevels: rawInfo.blackLevels,
            whiteLevel: rawInfo.whiteLevel,
            asShotNeutral: file.asShotNeutral,
            colorMatrix2: file.colorMatrix2)
        signposter.endInterval("halfsize", renderState)
        return image
    }

    /// raw を LJ92 デコードしてフル解像度の bilinear デモザイク画像を返す。
    /// 100%等倍のピント確認用（重いので等倍要求時に遅延実行する）
    public static func fullSizeImage(from file: DNGFile) throws -> RGBA8Image {
        guard let rawInfo = file.raw else { throw DecodeError.noRawData }
        guard rawInfo.compression == 7 else {
            throw DecodeError.unsupportedLayout("compression \(rawInfo.compression)")
        }
        guard let data = file.rawDataContiguous() else { throw DecodeError.noRawData }

        let decodeState = signposter.beginInterval("lj92")
        let raw = try LJ92Decoder.decode(data)
        signposter.endInterval("lj92", decodeState)

        guard raw.width == rawInfo.pixelSize.width, raw.height == rawInfo.pixelSize.height
        else {
            throw DecodeError.unsupportedLayout(
                "decoded \(raw.width)x\(raw.height) != tag \(rawInfo.pixelSize)")
        }

        let renderState = signposter.beginInterval("demosaic")
        let image = FullDemosaicRenderer.render(
            raw: raw,
            cfaPattern: rawInfo.cfaPattern,
            blackLevels: rawInfo.blackLevels,
            whiteLevel: rawInfo.whiteLevel,
            asShotNeutral: file.asShotNeutral,
            colorMatrix2: file.colorMatrix2)
        signposter.endInterval("demosaic", renderState)
        return image
    }
}
