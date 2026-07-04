import Foundation
import Testing
@testable import XMPKit

@Suite("サイドカーURL")
struct SidecarURLTests {
    @Test func 拡張子をxmpに置き換える() {
        let dng = URL(fileURLWithPath: "/photos/L1030505.DNG")
        #expect(XMPSidecar.url(for: dng).path == "/photos/L1030505.xmp")
    }

    @Test func 小文字拡張子でも同じ() {
        let dng = URL(fileURLWithPath: "/photos/img_001.dng")
        #expect(XMPSidecar.url(for: dng).path == "/photos/img_001.xmp")
    }
}

@Suite("XMP文字列の読み取り")
struct RatingParseTests {
    @Test func 属性形式() {
        let xml = #"<rdf:Description xmp:Rating="4"/>"#
        #expect(XMPSidecar.rating(in: xml) == 4)
    }

    @Test func 要素形式() {
        let xml = "<xmp:Rating>2</xmp:Rating>"
        #expect(XMPSidecar.rating(in: xml) == 2)
    }

    @Test func 除外はマイナス1() {
        #expect(XMPSidecar.rating(in: #"xmp:Rating="-1""#) == -1)
    }

    @Test func レートなしはnil() {
        #expect(XMPSidecar.rating(in: "<rdf:Description/>") == nil)
        #expect(XMPSidecar.rating(in: "") == nil)
    }

    @Test func 空白入り属性() {
        #expect(XMPSidecar.rating(in: #"xmp:Rating = "5""#) == 5)
    }
}

@Suite("XMP文字列の更新")
struct RatingUpsertTests {
    @Test func 属性形式の値を置き換える() throws {
        let xml = #"<rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2" crs:Exposure="+0.5"/>"#
        let updated = try #require(XMPSidecar.upsertRating(in: xml, rating: 5))
        #expect(updated.contains(#"xmp:Rating="5""#))
        // 他の属性は保全される
        #expect(updated.contains(#"crs:Exposure="+0.5""#))
    }

    @Test func 要素形式の値を置き換える() throws {
        let xml = "<rdf:Description><xmp:Rating>1</xmp:Rating></rdf:Description>"
        let updated = try #require(XMPSidecar.upsertRating(in: xml, rating: 3))
        #expect(updated.contains("<xmp:Rating>3</xmp:Rating>"))
    }

    @Test func レートなしのXMPには挿入する() throws {
        let xml = #"<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreatorTool="LR"/>"#
        let updated = try #require(XMPSidecar.upsertRating(in: xml, rating: 4))
        #expect(XMPSidecar.rating(in: updated) == 4)
        #expect(updated.contains(#"xmp:CreatorTool="LR""#))
    }

    @Test func xmlns宣言がなければ追加する() throws {
        let xml = #"<rdf:Description rdf:about=""/>"#
        let updated = try #require(XMPSidecar.upsertRating(in: xml, rating: 2))
        #expect(updated.contains(#"xmlns:xmp="http://ns.adobe.com/xap/1.0/""#))
        #expect(XMPSidecar.rating(in: updated) == 2)
    }

    @Test func Lightroom風の現像設定入りXMPを破壊しない() throws {
        let xml = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
                xmp:Rating="1"
                crs:Version="15.0"
                crs:Exposure2012="+0.85"
                crs:WhiteBalance="As Shot">
               <crs:ToneCurvePV2012>
                <rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq>
               </crs:ToneCurvePV2012>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        let updated = try #require(XMPSidecar.upsertRating(in: xml, rating: 5))
        #expect(XMPSidecar.rating(in: updated) == 5)
        // 現像設定は一切変わらない
        #expect(updated.contains(#"crs:Exposure2012="+0.85""#))
        #expect(updated.contains("<rdf:li>255, 255</rdf:li>"))
        // Rating の置換以外は同一（差分は 1→5 の1文字だけ）
        #expect(updated.replacingOccurrences(of: #"xmp:Rating="5""#, with: #"xmp:Rating="1""#) == xml)
    }

    @Test func rdfDescriptionが無い文書は更新拒否() {
        #expect(XMPSidecar.upsertRating(in: "<html>not xmp</html>", rating: 3) == nil)
        #expect(XMPSidecar.upsertRating(in: "", rating: 3) == nil)
    }
}

@Suite("ラベルの読み書き")
struct LabelTests {
    @Test func 属性形式の読み取り() {
        #expect(XMPSidecar.label(in: #"<rdf:Description xmp:Label="Red"/>"#) == "Red")
        #expect(XMPSidecar.label(in: "<xmp:Label>Blue</xmp:Label>") == "Blue")
        #expect(XMPSidecar.label(in: "<rdf:Description/>") == nil)
    }

    @Test func ラベルの挿入と置換() throws {
        let xml = #"<rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3"/>"#
        let inserted = try #require(XMPSidecar.upsertLabel(in: xml, label: "Yellow"))
        #expect(XMPSidecar.label(in: inserted) == "Yellow")
        #expect(XMPSidecar.rating(in: inserted) == 3, "Ratingは保全される")

        let replaced = try #require(XMPSidecar.upsertLabel(in: inserted, label: "Green"))
        #expect(XMPSidecar.label(in: replaced) == "Green")
    }

    @Test func nilでラベルを除去() throws {
        let xml = #"<rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="Red" xmp:Rating="2"/>"#
        let removed = try #require(XMPSidecar.upsertLabel(in: xml, label: nil))
        #expect(XMPSidecar.label(in: removed) == nil)
        #expect(XMPSidecar.rating(in: removed) == 2)
    }

    @Test func ファイル往復とレートとの共存() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMPKitLabel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("L1000010.DNG")

        // ラベルのみ → レート追加 → ラベル変更 → 両方残る
        try XMPSidecar.writeLabel("Red", forImageAt: image)
        #expect(XMPSidecar.readLabel(forImageAt: image) == "Red")

        try XMPSidecar.writeRating(4, forImageAt: image)
        try XMPSidecar.writeLabel("Blue", forImageAt: image)
        #expect(XMPSidecar.readLabel(forImageAt: image) == "Blue")
        #expect(XMPSidecar.readRating(forImageAt: image) == 4)

        try XMPSidecar.writeLabel(nil, forImageAt: image)
        #expect(XMPSidecar.readLabel(forImageAt: image) == nil)
        #expect(XMPSidecar.readRating(forImageAt: image) == 4)
    }

    @Test func ファイルなしでラベル除去は何もしない() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMPKitLabel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("L1000011.DNG")
        try XMPSidecar.writeLabel(nil, forImageAt: image)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecar.url(for: image).path))
    }
}

@Suite("ファイルの読み書き")
struct SidecarFileTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMPKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func 新規サイドカー作成と往復() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("L1000001.DNG")

        try XMPSidecar.writeRating(3, forImageAt: image)

        let sidecar = XMPSidecar.url(for: image)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(XMPSidecar.readRating(forImageAt: image) == 3)

        let content = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(content.contains("<?xpacket begin="))
        #expect(content.contains("x:xmpmeta"))
    }

    @Test func 既存サイドカーの更新() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("L1000002.DNG")

        try XMPSidecar.writeRating(2, forImageAt: image)
        try XMPSidecar.writeRating(-1, forImageAt: image)
        #expect(XMPSidecar.readRating(forImageAt: image) == -1)

        try XMPSidecar.writeRating(0, forImageAt: image)
        #expect(XMPSidecar.readRating(forImageAt: image) == 0)
    }

    @Test func サイドカーが無ければ読み取りはnil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("L1000003.DNG")
        #expect(XMPSidecar.readRating(forImageAt: image) == nil)
    }

    @Test func 解釈不能な既存ファイルは上書きせずエラー() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("L1000004.DNG")
        let sidecar = XMPSidecar.url(for: image)
        let garbage = "これはXMPではないファイル"
        try garbage.write(to: sidecar, atomically: true, encoding: .utf8)

        #expect(throws: XMPSidecarError.unrecognizedFormat) {
            try XMPSidecar.writeRating(4, forImageAt: image)
        }
        // 中身は無傷
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == garbage)
    }
}
