import DNGKit
import Foundation
import ImageIO
import SwiftUI

/// 撮影情報パネル（Iキー）に出す内容。DNGヘッダのIFD走査だけで得られる軽量情報
struct CaptureInfo: Sendable, Equatable {
    let capture: CaptureMetadata
    let cameraModel: String?
    /// センサー（raw）の画素寸法
    let sensorPixelSize: PixelSize?
    let fileByteCount: Int?
}

/// 撮影情報の読み込みとキャッシュ。パースはIFD走査のみで数百µsだが、
/// キー送りのたびの再パースを避けるためURLキーで保持する（メタデータのみで軽量）
actor CaptureInfoProvider {
    private var cache: [URL: CaptureInfo] = [:]

    func info(for url: URL) -> CaptureInfo? {
        if let cached = cache[url] { return cached }
        guard let info = url.isJPEGFile ? Self.jpegInfo(for: url) : Self.dngInfo(for: url)
        else { return nil }
        cache[url] = info
        return info
    }

    private static func dngInfo(for url: URL) -> CaptureInfo? {
        guard let file = try? DNGFile(contentsOf: url) else { return nil }
        return CaptureInfo(
            capture: file.capture,
            cameraModel: file.model,
            sensorPixelSize: file.raw?.pixelSize,
            fileByteCount: try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// JPGはImageIOのプロパティ辞書からExifを読み、DNGと同じ型に揃える
    private static func jpegInfo(for url: URL) -> CaptureInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var pixelSize: PixelSize?
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            pixelSize = PixelSize(width: w, height: h)
        }
        let capture = CaptureMetadata(
            exposureTimeSeconds: exif?[kCGImagePropertyExifExposureTime] as? Double,
            fNumber: exif?[kCGImagePropertyExifFNumber] as? Double,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            focalLengthMM: exif?[kCGImagePropertyExifFocalLength] as? Double,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            dateTimeOriginal: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exposureBiasEV: exif?[kCGImagePropertyExifExposureBiasValue] as? Double)
        return CaptureInfo(
            capture: capture,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            sensorPixelSize: pixelSize,
            fileByteCount: try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }
}

/// 撮影情報の表示整形。M262 の「レンズ未認識」（"not selected" / 0.0mm）は行ごと省く
enum CaptureFormat {
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 1 {
            let text = String(format: "%.1f", seconds)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "s"
        }
        return "1/\(Int((1 / seconds).rounded()))s"
    }

    static func aperture(_ f: Double) -> String {
        let text = String(format: "%.1f", f)
        return "f/" + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }

    /// 露出補正。0（未補正）は表示しない
    static func bias(_ ev: Double) -> String? {
        guard abs(ev) > 0.01 else { return nil }
        return String(format: "%+.1fEV", ev)
    }

    /// "2026:06:28 11:54:46" → "2026/06/28 11:54:46"
    static func dateTime(_ exif: String) -> String {
        let parts = exif.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return exif }
        return parts[0].replacingOccurrences(of: ":", with: "/") + " " + parts[1]
    }

    static func pixels(_ size: PixelSize) -> String {
        let mp = Double(size.area) / 1_000_000
        return String(format: "%d×%d (%.1fMP)", size.width, size.height, mp)
    }

    static func fileSize(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    /// 露出3要素を1行に。M262はF値を持たない（レンジファインダー）ので抜ける
    static func exposureLine(_ c: CaptureMetadata) -> String {
        var parts: [String] = []
        if let ss = c.exposureTimeSeconds { parts.append(shutter(ss)) }
        if let f = c.fNumber { parts.append(aperture(f)) }
        if let iso = c.iso { parts.append("ISO \(iso)") }
        if let ev = c.exposureBiasEV, let text = bias(ev) { parts.append(text) }
        return parts.joined(separator: "  ")
    }

    /// レンズ行。M262の非コードレンズ（"not selected"/0mm）は nil で行ごと省く
    static func lensLine(_ c: CaptureMetadata) -> String? {
        var parts: [String] = []
        if let mm = c.focalLengthMM, mm > 0 {
            let text = String(format: "%.0fmm", mm)
            parts.append(text)
        }
        if let lens = c.lensModel, !lens.isEmpty, lens != "not selected" {
            parts.append(lens)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

/// Iキーでトグルする撮影情報オーバーレイ（右上）
struct InfoPanelView: View {
    let url: URL
    let provider: CaptureInfoProvider

    @State private var info: CaptureInfo?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let info {
                let c = info.capture
                if let date = c.dateTimeOriginal {
                    Text(CaptureFormat.dateTime(date))
                        .foregroundStyle(.secondary)
                }
                let exposure = CaptureFormat.exposureLine(c)
                if !exposure.isEmpty {
                    Text(exposure)
                        .fontWeight(.semibold)
                }
                if let lens = CaptureFormat.lensLine(c) {
                    Text(lens)
                }
                if let model = info.cameraModel {
                    Text(model)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let size = info.sensorPixelSize {
                        Text(CaptureFormat.pixels(size))
                    }
                    if let bytes = info.fileByteCount {
                        Text(CaptureFormat.fileSize(bytes))
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                Text("読み込み中…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassPanel(cornerRadius: 10)
        .task(id: url) {
            info = await provider.info(for: url)
        }
    }
}
