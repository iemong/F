import Foundation

public enum DNGError: Error, Equatable, Sendable {
    case invalidHeader
    case outOfBounds(offset: Int, size: Int)
    case malformed(String)
}

public enum ByteOrder: Sendable, Equatable {
    case little
    case big
}

public struct PixelSize: Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public var area: Int { width * height }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// TIFF/EXIF Orientation (tag 0x0112)
public enum Orientation: UInt16, Sendable {
    case topLeft = 1
    case topRight = 2
    case bottomRight = 3
    case bottomLeft = 4
    case leftTop = 5
    case rightTop = 6
    case rightBottom = 7
    case leftBottom = 8

    /// 90度系（表示時に幅と高さが入れ替わる）かどうか
    public var swapsDimensions: Bool { rawValue >= 5 }
}

public enum PreviewSource: Sendable, Equatable {
    case ifd0
    /// SubIFDs 配列内のインデックス
    case subIFD(Int)
    /// Leica MakerNotes tag 0x0300
    case makerNote
}

public enum PreviewKind: Sendable, Equatable {
    /// IFD0 の極小サムネ（M262: 160×120 / Q3: 720×480）
    case thumbnail
    /// 中間プレビュー
    case midsize
    /// raw 比 80% 以上の実質原寸 JPEG（Q3 の JpgFromRaw）
    case fullsize
}

/// 埋め込み JPEG の所在。データ本体は持たず、ファイル内のバイト範囲だけを指す
public struct PreviewDescriptor: Sendable, Equatable {
    public let kind: PreviewKind
    public let source: PreviewSource
    public let pixelSize: PixelSize
    public let byteRange: Range<Int>
}

/// 撮影時の主要Exif（セレクト時の情報表示用）。値はファイルに書かれたままで、
/// M262 の "not selected"（非コードレンズ）等の表示上の解釈は呼び出し側の責務
public struct CaptureMetadata: Sendable, Equatable {
    /// 露光時間（秒）
    public let exposureTimeSeconds: Double?
    /// F値。Mボディ（レンジファインダー）は絞りを検知できないため nil
    public let fNumber: Double?
    public let iso: Int?
    /// 焦点距離（mm）。M262 の非コードレンズは 0
    public let focalLengthMM: Double?
    public let lensModel: String?
    /// Exif 生文字列 "yyyy:MM:dd HH:mm:ss"
    public let dateTimeOriginal: String?
    /// 露出補正（EV）
    public let exposureBiasEV: Double?
}

/// raw 本体（CFA）の所在情報。デコードは DecodeKit の責務
public struct RawInfo: Sendable, Equatable {
    public let pixelSize: PixelSize
    public let bitsPerSample: Int
    /// TIFF Compression 値。7 = lossless JPEG (LJ92)
    public let compression: Int
    public let byteRanges: [Range<Int>]
    /// 2×2 CFA 配置（行優先）。0=R, 1=G, 2=B。Q3: [0,1,1,2]=RGGB / M262: [2,1,1,0]=BGGR
    public let cfaPattern: [UInt8]
    /// CFA 位置ごとのブラックレベル（4要素。スカラー指定は4要素に展開）
    public let blackLevels: [Double]
    public let whiteLevel: Int

    public var totalByteCount: Int { byteRanges.reduce(0) { $0 + $1.count } }
}
