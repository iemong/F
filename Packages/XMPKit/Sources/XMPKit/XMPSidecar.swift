import Foundation

public enum XMPSidecarError: Error, Equatable, Sendable {
    /// 既存ファイルが XMP として解釈できない（破壊を避けるため書き込み拒否）
    case unrecognizedFormat
    case notUTF8
}

/// XMPサイドカー（Lightroom / Capture One 互換）のレート読み書き。
///
/// - レートは `xmp:Rating`（0-5、除外は -1 = XMP標準のreject表現）
/// - 既存サイドカーは xmp:Rating だけをピンポイント更新し、
///   現像設定など他の内容には一切触れない
/// - 元画像ファイルには何も書き込まない（サイドカーのみ）
public enum XMPSidecar {
    /// 画像URL → サイドカーURL（拡張子を .xmp に置換）
    public static func url(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// レートを書き込む。サイドカーが無ければ新規作成、あれば保全更新。
    /// 既存ファイルが解釈不能な場合は上書きせず unrecognizedFormat を投げる
    public static func writeRating(_ rating: Int, forImageAt imageURL: URL) throws {
        let sidecar = url(for: imageURL)
        let content: String
        if FileManager.default.fileExists(atPath: sidecar.path) {
            guard let data = try? Data(contentsOf: sidecar),
                let existing = String(data: data, encoding: .utf8)
            else { throw XMPSidecarError.notUTF8 }
            guard let updated = upsertRating(in: existing, rating: rating) else {
                throw XMPSidecarError.unrecognizedFormat
            }
            content = updated
        } else {
            content = freshDocument(rating: rating)
        }
        try Data(content.utf8).write(to: sidecar, options: .atomic)
    }

    /// サイドカーからレートを読む。ファイルなし/レートなしは nil
    public static func readRating(forImageAt imageURL: URL) -> Int? {
        let sidecar = url(for: imageURL)
        guard let data = try? Data(contentsOf: sidecar),
            let content = String(data: data, encoding: .utf8)
        else { return nil }
        return rating(in: content)
    }

    /// カラーラベル（xmp:Label、Lightroom/C1互換。"Red"/"Yellow"/"Green"/"Blue"等）を書く。
    /// nil はラベル除去。ファイルが無くラベルも nil なら何もしない
    public static func writeLabel(_ label: String?, forImageAt imageURL: URL) throws {
        let sidecar = url(for: imageURL)
        let content: String
        if FileManager.default.fileExists(atPath: sidecar.path) {
            guard let data = try? Data(contentsOf: sidecar),
                let existing = String(data: data, encoding: .utf8)
            else { throw XMPSidecarError.notUTF8 }
            guard let updated = upsertLabel(in: existing, label: label) else {
                throw XMPSidecarError.unrecognizedFormat
            }
            content = updated
        } else {
            guard let label else { return }
            content = freshDocument(rating: nil, label: label)
        }
        try Data(content.utf8).write(to: sidecar, options: .atomic)
    }

    /// サイドカーからラベルを読む。ファイルなし/ラベルなしは nil
    public static func readLabel(forImageAt imageURL: URL) -> String? {
        let sidecar = url(for: imageURL)
        guard let data = try? Data(contentsOf: sidecar),
            let content = String(data: data, encoding: .utf8)
        else { return nil }
        return label(in: content)
    }

    // MARK: - XMP文字列操作（テスト用にinternal公開）

    static func rating(in xml: String) -> Int? {
        if let match = xml.firstMatch(of: /xmp:Rating\s*=\s*"(-?\d+)"/) {
            return Int(match.1)
        }
        if let match = xml.firstMatch(of: /<xmp:Rating>\s*(-?\d+)\s*<\/xmp:Rating>/) {
            return Int(match.1)
        }
        return nil
    }

    /// xmp:Rating を更新または挿入する。他の内容には触れない。
    /// rdf:Description が見つからない文書は nil（呼び出し側で書き込み拒否）
    static func upsertRating(in xml: String, rating: Int) -> String? {
        // 属性形式
        if let range = xml.firstRange(of: /xmp:Rating\s*=\s*"[^"]*"/) {
            return xml.replacingCharacters(in: range, with: "xmp:Rating=\"\(rating)\"")
        }
        // 要素形式
        if let range = xml.firstRange(of: /<xmp:Rating>[^<]*<\/xmp:Rating>/) {
            return xml.replacingCharacters(
                in: range, with: "<xmp:Rating>\(rating)</xmp:Rating>")
        }
        // レート未記載 → 最初の rdf:Description 開始タグに属性を挿入
        if let range = xml.firstRange(of: /<rdf:Description\b/) {
            var insertion = " xmp:Rating=\"\(rating)\""
            if !xml.contains("xmlns:xmp=") {
                insertion = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + insertion
            }
            return xml.replacingCharacters(in: range, with: "<rdf:Description" + insertion)
        }
        return nil
    }

    static func label(in xml: String) -> String? {
        if let match = xml.firstMatch(of: /xmp:Label\s*=\s*"([^"]*)"/) {
            let value = String(match.1)
            return value.isEmpty ? nil : value
        }
        if let match = xml.firstMatch(of: /<xmp:Label>\s*([^<]*?)\s*<\/xmp:Label>/) {
            let value = String(match.1)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// xmp:Label を更新/挿入/除去する。他の内容には触れない
    static func upsertLabel(in xml: String, label: String?) -> String? {
        if let label {
            if let range = xml.firstRange(of: /xmp:Label\s*=\s*"[^"]*"/) {
                return xml.replacingCharacters(in: range, with: "xmp:Label=\"\(label)\"")
            }
            if let range = xml.firstRange(of: /<xmp:Label>[^<]*<\/xmp:Label>/) {
                return xml.replacingCharacters(
                    in: range, with: "<xmp:Label>\(label)</xmp:Label>")
            }
            if let range = xml.firstRange(of: /<rdf:Description\b/) {
                var insertion = " xmp:Label=\"\(label)\""
                if !xml.contains("xmlns:xmp=") {
                    insertion = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + insertion
                }
                return xml.replacingCharacters(in: range, with: "<rdf:Description" + insertion)
            }
            return nil
        }
        // 除去（前置スペースごと消す。要素形式も対応）
        if let range = xml.firstRange(of: /\s*xmp:Label\s*=\s*"[^"]*"/) {
            return xml.replacingCharacters(in: range, with: "")
        }
        if let range = xml.firstRange(of: /\s*<xmp:Label>[^<]*<\/xmp:Label>/) {
            return xml.replacingCharacters(in: range, with: "")
        }
        return xml // ラベル未記載なら無変更
    }

    static func freshDocument(rating: Int?, label: String? = nil) -> String {
        var attributes = ""
        if let rating { attributes += "\n    xmp:Rating=\"\(rating)\"" }
        if let label { attributes += "\n    xmp:Label=\"\(label)\"" }
        return """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="LeicaSelect">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"\(attributes)/>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
    }
}
