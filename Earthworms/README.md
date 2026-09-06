# ミミズ (Earthworms)

「日本産ミミズのリスト」を使用する。

## 自動ダウンロードされるファイル

| ファイル | 形式 | 情報源 |
|---|---|---|
| `nihonsan_mimizu_list.xlsx` | Excel | `https://japanese-mimizu.jimdofree.com/app/download/9610532191/11.+日本産ミミズのリスト.xlsx?t=1759044652`（URL は percent-encoded） |

案内ページは https://japanese-mimizu.jimdofree.com/ミミズの分類/ 。

## 手動で配置するファイル

なし。

## 補足

- サイトには「当サイト内に記載された文章、写真、絵画などの無断転載を禁じます」とあるが、xlsx は明示的な「ダウンロード」ボタンで提供され、robots.txt も `Disallow: /app/` に対し `Allow: /app/download/` と明示的に許可している。ダウンロードして各自が加工する行為は転載に当たらず、データを再配布しない JBTaxon とは衝突しない。
- robots.txt に **`Crawl-Delay: 5`** がある。`fetch_data.pl` は全ダウンロード間に5秒の間隔を空けるので自動的に満たされる。
- ファイル名に版が入る URL なので、新しい版が出たときは `fetch_data.pl` 自体を更新して対応する。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
