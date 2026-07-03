import DNGKit
import Foundation

/// 検証用CLI: DNGKitのパース結果をTSVで出力し、exiftoolとのクロスチェックに使う
let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    print("usage: dngdump <file.DNG> ...")
    exit(1)
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    do {
        let file = try DNGFile(contentsOf: url)
        var fields: [String] = [
            url.lastPathComponent,
            file.byteOrder == .little ? "II" : "MM",
            file.model ?? "?",
            "o\(file.orientation.rawValue)",
        ]
        if let raw = file.raw {
            fields.append(
                "raw=\(raw.pixelSize.width)x\(raw.pixelSize.height)"
                    + "@\(raw.bitsPerSample)bit,c\(raw.compression),\(raw.totalByteCount)B")
        } else {
            fields.append("raw=none")
        }
        for p in file.previews {
            fields.append(
                "\(p.kind):\(p.pixelSize.width)x\(p.pixelSize.height)"
                    + ":\(p.byteRange.count)B@\(p.byteRange.lowerBound)")
        }
        print(fields.joined(separator: "\t"))
    } catch {
        print("\(url.lastPathComponent)\tERROR\t\(error)")
    }
}
