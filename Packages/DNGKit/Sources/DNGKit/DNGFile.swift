import Foundation

/// DNG コンテナのパース結果。読み取り専用で、元ファイルには一切書き込まない。
///
/// - Q3: IFD0(サムネ) + SubIFD0(raw) + SubIFD1(中間) + SubIFD2(実質原寸JPEG)
/// - M262: IFD0(極小サムネ) + SubIFD0(raw) + Leica MakerNotes 0x0300(1472×976)
public struct DNGFile: Sendable {
    public let byteOrder: ByteOrder
    public let model: String?
    public let orientation: Orientation
    /// ピクセル面積の降順
    public let previews: [PreviewDescriptor]
    public let raw: RawInfo?
    /// 撮影時ホワイトバランスのニュートラル値（カメラRGB、G=1基準）
    public let asShotNeutral: [Double]?
    /// XYZ(D65)→カメラRGB の 3×3 行列（行優先9要素）
    public let colorMatrix2: [Double]?

    private let fileData: Data

    public init(contentsOf url: URL) throws {
        // mappedIfSafe: 20MB超のファイルを開いてもプレビュー範囲のページしか実読しない
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data)
    }

    public init(data: Data) throws {
        let header = [UInt8](data.prefix(8))
        guard header.count == 8 else { throw DNGError.invalidHeader }
        let order: ByteOrder =
            switch (header[0], header[1]) {
            case (0x49, 0x49): .little
            case (0x4D, 0x4D): .big
            default: throw DNGError.invalidHeader
            }
        let reader = ByteReader(data: data, order: order)
        guard try reader.u16(at: 2) == 42 else { throw DNGError.invalidHeader }

        let ifd0 = try IFD.parse(reader, at: Int(try reader.u32(at: 4)))

        var collected: [(source: PreviewSource, size: PixelSize, range: Range<Int>)] = []
        var rawInfo: RawInfo?

        if let p = try Self.jpegPreview(in: ifd0, reader: reader, source: .ifd0) {
            collected.append(p)
        }

        if let subEntry = ifd0[TIFFTag.subIFDs] {
            for (index, offset) in try subEntry.uints(reader).enumerated() {
                let sub = try IFD.parse(reader, at: Int(offset))
                let photometric = try sub[TIFFTag.photometric]?.uint(reader) ?? 0
                if photometric == TIFFTag.photometricCFA {
                    rawInfo = try Self.rawInfo(in: sub, reader: reader)
                } else if let p = try Self.jpegPreview(
                    in: sub, reader: reader, source: .subIFD(index))
                {
                    collected.append(p)
                }
            }
        }

        if let exifEntry = ifd0[TIFFTag.exifIFD],
            let exifOffset = try exifEntry.uint(reader),
            let exifIFD = try? IFD.parse(reader, at: Int(exifOffset)),
            let makerNote = exifIFD[TIFFTag.makerNote],
            let p = Self.leicaMakerNotePreview(entry: makerNote, reader: reader)
        {
            collected.append(p)
        }

        let rawArea = rawInfo?.pixelSize.area
        self.previews =
            collected
            .map { c in
                let kind: PreviewKind =
                    if let rawArea, c.size.area * 5 >= rawArea * 4 {
                        .fullsize
                    } else if c.source == .ifd0 {
                        .thumbnail
                    } else {
                        .midsize
                    }
                return PreviewDescriptor(
                    kind: kind, source: c.source, pixelSize: c.size, byteRange: c.range)
            }
            .sorted { $0.pixelSize.area > $1.pixelSize.area }

        self.byteOrder = order
        self.model = try ifd0[TIFFTag.model]?.string(reader)
        let orientationRaw = try ifd0[TIFFTag.orientation]?.uint(reader) ?? 1
        self.orientation = Orientation(rawValue: UInt16(clamping: orientationRaw)) ?? .topLeft
        self.raw = rawInfo

        let neutral = try ifd0[TIFFTag.asShotNeutral]?.doubles(reader)
        self.asShotNeutral = neutral?.count == 3 ? neutral : nil
        let matrix = try ifd0[TIFFTag.colorMatrix2]?.doubles(reader)
        self.colorMatrix2 = matrix?.count == 9 ? matrix : nil

        self.fileData = data
    }

    // MARK: - 抽出

    /// プレビューの JPEG データを切り出す（コピー）
    public func previewData(_ descriptor: PreviewDescriptor) -> Data {
        fileData.subdata(in: descriptor.byteRange)
    }

    /// raw ストリップのデータを切り出す（コピー）。デコードは DecodeKit の責務
    public func rawData() -> Data? {
        guard let raw, let range = raw.byteRanges.first, raw.byteRanges.count == 1 else {
            return nil
        }
        return fileData.subdata(in: range)
    }

    public var largestPreview: PreviewDescriptor? { previews.first }

    /// target 以上の寸法を持つ最小のプレビューを返す。なければ最大のものにフォールバック
    public func bestPreview(fitting target: PixelSize) -> PreviewDescriptor? {
        previews
            .filter { $0.pixelSize.width >= target.width && $0.pixelSize.height >= target.height }
            .min { $0.pixelSize.area < $1.pixelSize.area }
            ?? previews.first
    }

    // MARK: - IFD 走査の詳細

    private static func jpegPreview(
        in ifd: IFD, reader: ByteReader, source: PreviewSource
    ) throws -> (source: PreviewSource, size: PixelSize, range: Range<Int>)? {
        var range: Range<Int>?
        if let so = ifd[TIFFTag.stripOffsets], let sc = ifd[TIFFTag.stripByteCounts] {
            let offsets = try so.uints(reader)
            let counts = try sc.uints(reader)
            // JPEGプレビューは単一ストリップのみ想定
            if offsets.count == 1, counts.count == 1 {
                range = Int(offsets[0]) ..< Int(offsets[0]) + Int(counts[0])
            }
        } else if let jo = try ifd[TIFFTag.jpegInterchangeFormat]?.uint(reader),
            let jl = try ifd[TIFFTag.jpegInterchangeFormatLength]?.uint(reader)
        {
            range = Int(jo) ..< Int(jo) + Int(jl)
        }
        guard let range, range.upperBound <= reader.count else { return nil }

        // JPEG マジック検証（無圧縮RGBサムネ等はスキップ）
        guard let magic = try? reader.slice(at: range.lowerBound, count: 2),
            magic.elementsEqual([0xFF, 0xD8])
        else { return nil }

        var size: PixelSize?
        if let w = try ifd[TIFFTag.imageWidth]?.uint(reader),
            let h = try ifd[TIFFTag.imageHeight]?.uint(reader)
        {
            size = PixelSize(width: Int(w), height: Int(h))
        } else if let sliced = try? reader.slice(
            at: range.lowerBound, count: min(range.count, 262_144))
        {
            size = JPEGSniffer.pixelSize(of: sliced)
        }
        guard let size else { return nil }
        return (source, size, range)
    }

    private static func rawInfo(in ifd: IFD, reader: ByteReader) throws -> RawInfo? {
        guard let w = try ifd[TIFFTag.imageWidth]?.uint(reader),
            let h = try ifd[TIFFTag.imageHeight]?.uint(reader),
            let so = ifd[TIFFTag.stripOffsets],
            let sc = ifd[TIFFTag.stripByteCounts]
        else { return nil }
        let offsets = try so.uints(reader)
        let counts = try sc.uints(reader)
        guard offsets.count == counts.count, !offsets.isEmpty else { return nil }
        let ranges = zip(offsets, counts).map { Int($0) ..< Int($0) + Int($1) }
        guard ranges.allSatisfy({ $0.upperBound <= reader.count }) else { return nil }

        let bits = Int(try ifd[TIFFTag.bitsPerSample]?.uint(reader) ?? 16)

        // CFA 2×2 前提（両機種とも CFARepeatPatternDim = 2 2）
        var cfa: [UInt8] = [0, 1, 1, 2]
        if let entry = ifd[TIFFTag.cfaPattern], entry.count == 4 {
            let values = try entry.uints(reader)
            if values.count == 4 { cfa = values.map { UInt8(clamping: $0) } }
        }

        // BlackLevel はスカラーまたは CFA 位置ごとの4要素（RATIONAL の場合もある）
        var blacks: [Double] = [0, 0, 0, 0]
        if let entry = ifd[TIFFTag.blackLevel] {
            let values = try entry.doubles(reader)
            if values.count == 1 {
                blacks = [Double](repeating: values[0], count: 4)
            } else if values.count == 4 {
                blacks = values
            }
        }

        let white = try ifd[TIFFTag.whiteLevel]?.uint(reader).map(Int.init)
            ?? ((1 << bits) - 1)

        return RawInfo(
            pixelSize: PixelSize(width: Int(w), height: Int(h)),
            bitsPerSample: bits,
            compression: Int(try ifd[TIFFTag.compression]?.uint(reader) ?? 1),
            byteRanges: ranges,
            cfaPattern: cfa,
            blackLevels: blacks,
            whiteLevel: white)
    }

    /// Leica MakerNotes: `LEICA\0` ヘッダ + 8バイト目から内部IFD（次IFDオフセットなし）。
    /// tag 0x0300 の値オフセットはファイル絶対（実測）だが、防御的に MakerNotes 相対も試し、
    /// JPEG マジックが一致した候補だけを採用する
    private static func leicaMakerNotePreview(
        entry: IFDEntry, reader: ByteReader
    ) -> (source: PreviewSource, size: PixelSize, range: Range<Int>)? {
        guard entry.type == 7, entry.count > 16 else { return nil }
        let base = entry.valueOffset
        guard let prefix = try? reader.slice(at: base, count: 6),
            prefix.elementsEqual(Array("LEICA".utf8) + [0])
        else { return nil }

        // 内部IFDのエンディアンはコンテナと同じ想定。エントリ数が不自然なら反転して再試行
        var innerReader = reader
        guard var entryCount = try? Int(innerReader.u16(at: base + 8)) else { return nil }
        if !(1 ..< 256).contains(entryCount) {
            innerReader = reader.withFlippedOrder()
            guard let flipped = try? Int(innerReader.u16(at: base + 8)),
                (1 ..< 256).contains(flipped)
            else { return nil }
            entryCount = flipped
        }

        guard
            let inner = try? IFD.parse(
                ByteReader(data: reader.data, order: innerReader.order),
                at: base + 8, hasNextOffset: false),
            let previewEntry = inner[TIFFTag.leicaPreview],
            previewEntry.type == 7, previewEntry.count > 4
        else { return nil }

        let length = previewEntry.count
        // IFD.parse は4バイト超の値を絶対オフセットとして解決済み。相対だった場合も試す
        for candidate in [previewEntry.valueOffset, base + previewEntry.valueOffset] {
            guard candidate >= 0, candidate + length <= reader.count,
                let magic = try? reader.slice(at: candidate, count: 2),
                magic.elementsEqual([0xFF, 0xD8]),
                let head = try? reader.slice(at: candidate, count: min(length, 262_144)),
                let size = JPEGSniffer.pixelSize(of: head)
            else { continue }
            return (.makerNote, size, candidate ..< candidate + length)
        }
        return nil
    }
}
