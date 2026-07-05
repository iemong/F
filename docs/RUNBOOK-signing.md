# CI 署名・公証のセットアップ

GitHub Actions で Developer ID 署名 + Apple 公証を自動化するための一度きりの準備。
完了後は `git tag vX.Y.Z && git push origin vX.Y.Z` だけで署名・公証済みDMGが出る。

Team ID: `6RSL327PX8` / 署名ID: `Developer ID Application: SHINNOSUKE IRIE (6RSL327PX8)`

## 必要な GitHub Secrets

| Secret名 | 中身 |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Developer ID Application 証明書(.p12)を base64 化した文字列 |
| `DEVELOPER_ID_CERT_PASSWORD` | 上記 .p12 をエクスポートするとき設定したパスワード |
| `ASC_KEY_ID` | App Store Connect APIキーの Key ID（10桁英数） |
| `ASC_ISSUER_ID` | 同 Issuer ID（UUID） |
| `ASC_KEY_P8` | 同 APIキー(.p8)を base64 化した文字列 |

## 手順

### 1. 署名証明書(.p12)をエクスポート

**キーチェーンアクセス.app** で:
1. 「ログイン」キーチェーン → 「自分の証明書」カテゴリ
2. `Developer ID Application: SHINNOSUKE IRIE (6RSL327PX8)` を右クリック → 書き出す
   - 有効期限が最も新しいもの（2029年まで）を選ぶ
3. `.p12` 形式で保存。**書き出しパスワードを設定**（これが `DEVELOPER_ID_CERT_PASSWORD`）

> 三角マークを開いて秘密鍵ごと選択して書き出すこと（証明書だけだと署名できない）。

### 2. App Store Connect API キーを作成

1. https://appstoreconnect.apple.com/access/integrations/api
2. 「チームキー」で新規キー発行。アクセス権は **Developer** で十分
3. `.p8` をダウンロード（**再ダウンロード不可**なので大切に）
4. 一覧に出る **Key ID** と、ページ上部の **Issuer ID** を控える

### 3. Secrets を登録

`.p12` と `.p8` のパスが分かれば、同梱スクリプトで一括登録できる:

```bash
scripts/set-release-secrets.sh \
  --p12 ~/path/to/DeveloperID.p12 \
  --p12-password 'エクスポート時のパスワード' \
  --p8 ~/path/to/AuthKey_XXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer 00000000-0000-0000-0000-000000000000
```

手動で登録する場合:

```bash
gh secret set DEVELOPER_ID_CERT_P12 < <(base64 -i ~/path/to/DeveloperID.p12)
gh secret set DEVELOPER_ID_CERT_PASSWORD --body 'エクスポート時のパスワード'
gh secret set ASC_KEY_ID --body 'XXXXXXXXXX'
gh secret set ASC_ISSUER_ID --body '00000000-0000-0000-0000-000000000000'
gh secret set ASC_KEY_P8 < <(base64 -i ~/path/to/AuthKey_XXXXXX.p8)
```

### 4. 動作確認

```bash
git tag v0.0.2
git push origin v0.0.2
```

Actions の Release ワークフローが署名→公証→staple まで通れば、
Release の `F-0.0.2.dmg` はダブルクリックで警告なく起動する。

## 仕組み（release.yml）

- Secrets があれば一時キーチェーンに .p12 を import し、hardened runtime 付きで
  Developer ID 署名 → DMG 署名 → notarytool 提出 → stapler
- Secrets が無ければ ad-hoc 署名にフォールバック（DMGは出るがGatekeeperで要右クリック）
- `ASC_KEY_P8` だけ無い場合は署名のみ（公証はスキップ）
