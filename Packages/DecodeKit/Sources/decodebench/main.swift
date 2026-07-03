import DecodeKit
import DNGKit
import Foundation

/// ベンチマーク: read / LJ92 / halfsize の各段を計測する。
/// --ppm を付けると結果画像を PPM(P6) で書き出す（目視確認用）
var arguments = Array(CommandLine.arguments.dropFirst())
let writePPM = arguments.contains("--ppm")
arguments.removeAll { $0 == "--ppm" }

guard !arguments.isEmpty else {
    print("usage: decodebench [--ppm] <file.DNG> ...")
    exit(1)
}

func ms(_ duration: Duration) -> String {
    String(format: "%7.1fms", Double(duration.components.attoseconds) / 1e15
        + Double(duration.components.seconds) * 1e3)
}

let clock = ContinuousClock()
print("file            \t   read\t   lj92\thalfsize\t  total\tsize")

for path in arguments {
    let url = URL(fileURLWithPath: path)
    do {
        let file = try DNGFile(contentsOf: url)
        guard let rawInfo = file.raw else {
            print("\(url.lastPathComponent)\trawなし")
            continue
        }

        var readTime = Duration.zero
        var data = Data()
        readTime = clock.measure {
            data = file.rawDataContiguous() ?? Data()
        }

        var raw: RawImage?
        let decodeTime = try clock.measure {
            raw = try LJ92Decoder.decode(data)
        }

        guard let raw else { continue }
        var image: RGBA8Image?
        let renderTime = clock.measure {
            image = HalfSizeRenderer.render(
                raw: raw,
                cfaPattern: rawInfo.cfaPattern,
                blackLevels: rawInfo.blackLevels,
                whiteLevel: rawInfo.whiteLevel,
                asShotNeutral: file.asShotNeutral,
                colorMatrix2: file.colorMatrix2)
        }

        guard let image else { continue }
        let total = readTime + decodeTime + renderTime
        print(
            "\(url.lastPathComponent)\t\(ms(readTime))\t\(ms(decodeTime))"
                + "\t\(ms(renderTime))\t\(ms(total))"
                + "\t\(image.width)x\(image.height)")

        if writePPM {
            var ppm = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
            ppm.reserveCapacity(ppm.count + image.width * image.height * 3)
            for i in stride(from: 0, to: image.pixels.count, by: 4) {
                ppm.append(image.pixels[i])
                ppm.append(image.pixels[i + 1])
                ppm.append(image.pixels[i + 2])
            }
            let out = url.deletingPathExtension().lastPathComponent + "_half.ppm"
            try ppm.write(to: URL(fileURLWithPath: out))
            print("  -> \(out)")
        }
    } catch {
        print("\(url.lastPathComponent)\tERROR\t\(error)")
    }
}
