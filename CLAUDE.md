# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

**F** — Leica M (Typ 262) / Q3 の DNG に特化した macOS 向け爆速セレクトビューワー。
RAW現像はせず、大量の撮影データから残す1枚を選び、結果をXMPサイドカーで
Lightroom / Capture One に引き継ぐためのツール。仕様の非ゴール: RAW現像・
Windows/Linux対応・M262/Q3以外の機種最適化はやらない。

## ビルド・テスト・実行

**アプリ（F.xcodeproj）のビルド/実行/停止は必ず XcodeBuildMCP のツールを使う。`xcodebuild` の生叩きは禁止。**
セッション開始時にまず `session_show_defaults` で project/scheme/config を確認する
（既定は project=F.xcodeproj / scheme=F / config=Release）。macOSワークフロー
（build_macos / build_run_macos / launch_mac_app / stop_mac_app）が
ToolSearch で見えない場合は MCP 再接続が必要。

```bash
# SPMパッケージのテスト（アプリと違い swift で回してよい）
swift test --package-path Packages/DNGKit          # 全体
swift test --package-path Packages/DecodeKit --filter "Q3"   # 単一Suite/テスト

# 検証用CLI（exiftool/librawとのクロスチェックに使う）
swift run --package-path Packages/DNGKit dngdump samples/*.DNG
swift run --package-path Packages/DecodeKit decodebench --ppm --full samples/L1007057.DNG
```

**アプリの動作確認は `--autotest` ハーネスを使う**: `F.app --folder <dir> --autotest`
で全ファイルを往復自動送りし、レイテンシ（glass=実提示 / app=アプリ処理 /
decode）を標準出力に吐いて終了する。`--folder <dir>` 単体で NSOpenPanel を
省略して直接開ける。注意: ウィンドウが他ウィンドウに完全に隠れると macOS が
present をドロップし glass=0ms になるため、計測時はウィンドウ可視が前提。

コンパイルだけ手早く確認したいときは scratchpad に SPM ミラーパッケージを作り
（`FApp/*.swift` をコピーして DNGKit/DecodeKit/CacheKit/XMPKit を依存に持つ
executableTarget を `swift build`）、xcodebuild を経由せず Swift 6 strict 同条件で通せる。

## アーキテクチャ

境界を守る5つのSPMパッケージ + UIと描画に徹する app ターゲット。

- **DNGKit** (Foundationのみ): DNGコンテナのパース。両エンディアン対応のIFD走査、
  埋め込みJPEG抽出、raw(LJ92)の所在情報。**UIKit/AppKit禁止**。書き込みAPIを持たず、
  `Data(contentsOf:options:.mappedIfSafe)` で開く読み取り専用設計
- **DecodeKit** (DNGKitに依存): Bayer→表示画像。LJ92(SOF3 lossless JPEG)デコーダ、
  ハーフサイズ縮約(2x2→1px)、フルデモザイク(bilinear)。色処理は `ColorPipeline` で共有
- **CacheKit** (単独): actor `LRUByteCache` — バイトコスト上限LRU + 先読み + インフライト合流
- **XMPKit** (単独): XMPサイドカーの Rating / Label / Keyword 読み書き
- **AppCore** (XMPKitに依存): ファイル列挙・表示対象選択・DNG/JPGペア・ゴミ箱計画・
  相対パスを維持する安全な書き出し。UI非依存で単体テストする
- **FApp** (F.xcodeproj): SwiftUI + NSViewRepresentable + CAMetalLayer直描画。上記5つを組む

SPMレベルの依存は DecodeKit→DNGKit と AppCore→XMPKit。CacheKit / XMPKit は独立。
app が全部をオーケストレーションする（`AppModel` が中心）。

### 機種別のデコード経路（Phase 0調査で確定、docs/dng-analysis.md）

- **Q3**: little-endian。SubIFD2 に実質原寸JPEG(JpgFromRaw)を持つ → 抽出してImageIOでデコードするだけ。等倍もこれで足りる
- **M262**: big-endian。使えるプレビューは Leica MakerNotes tag 0x0300 の1472×976のみ →
  raw(LJ92)を自前デコード + ハーフサイズ縮約。等倍要求時のみフルデモザイクを遅延実行
- 両機種とも raw は SOF3 / 14bit / 2成分Bayerパック / 単一ストリップ。LJ92デコーダは1本で共用

### 描画・キャッシュの要点（AppModel / MetalImageView）

- テクスチャは `LRUByteCache<FrameKey, TextureFrame>`(2GB上限)に保持。前方2枚・後方1枚を先読み
- キー送りヒット時は MainActor 側ホットミラー + `MetalLayerView` への直接参照で
  SwiftUIの更新サイクル(+1 vsync)を迂回し、同一ランループでコマンドバッファをcommit
- `FrameKey(url, full)` で通常表示とフル解像(等倍)を別キャッシュ管理
- present完了はフレームidの世代ガードで判定（古いフレームの再presentを計測から除外）
- Orientation は回転をテクスチャに焼かず、クアッドのUV割当で正立表示にする（MetalImageView.cornerUVs）

## 守るべき不変条件

- **元のDNGには絶対に書き込まない**。レート/ラベル/タグは全て `<basename>.xmp` サイドカーに書く。
  既存XMPは該当タグだけをピンポイント更新し、現像設定など他の内容は1バイトも触らない
  （解釈不能なファイルは上書き拒否）。書き込みは `.atomic`
- **Swift 6 strict concurrency**。Sendable警告は握りつぶさず設計で解決する。
  不変利用の MTLTexture/CGImage は生成後不変の契約下で `@unchecked Sendable`
- 性能は計測で判定する（推測で最適化しない）。os_signpost は subsystem `F.App` / `F.DecodeKit`。
  数値目標と実測は docs/performance.md
- ホットループでは mutable var のクロージャキャプチャを避ける（ボックス化で約2倍遅くなった実績）。
  inout引数の静的関数に置く

## テスト方針

- DNGKit はテストファースト。`samples/` の実機DNG（Q3×10 / M262×11、**git管理外**）を
  フィクスチャに、docs/dng-analysis.md の exiftool/xxd 実測値をリファレンスにする。
  samples/ が無い環境では該当テストは `.enabled(if: Fixtures.hasSamples)` で自動スキップ
- LJ92デコーダはテスト内の最小エンコーダでラウンドトリップ検証 + libraw(rawpy)出力との全画素一致
- AppCore は一時ディレクトリを使い、列挙・選択・ペア・ゴミ箱・書き出しを実ファイルで検証する
- 正解データ採取には rawpy(libraw)を使う（scratchpadにvenvを作る）

## リリース

`F.xcodeproj` の pbxproj は**手書き**（objectVersion 77 / FileSystemSynchronizedRootGroup）。
新ファイルはディレクトリに置けば自動で拾われる。パッケージ追加時のみ pbxproj に
packageReference/productDependency を足す。

`v*` タグをpushすると `.github/workflows/release.yml` が署名→公証→staple→
DMGをGitHub Releaseに添付まで自動実行（GitHub Secrets設定済み。詳細は docs/RUNBOOK-signing.md）。
バージョンは `MARKETING_VERSION` を上げてからタグを打つ。CIは push/PR で5パッケージの
`swift test` + Releaseビルド。

## タスク管理

複雑な作業では `.claude/tasks/active/` にMarkdownのチェックリストを作り、完了時に
`.claude/tasks/completed/` へ移す（TodoWrite/TodoReadは使わない）。`.claude/` はgit管理外。
