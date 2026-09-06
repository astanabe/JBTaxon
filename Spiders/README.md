# クモ類 (Spiders)

NARO 昆虫インベントリーデータベースの Araneae (category=`BB00006378`, 255件) を使用する。

## 自動ダウンロードされるファイル

| ファイル | 数 | 形式 | 情報源 |
|---|---:|---|---|
| `naro_araneae_page001.html` 〜 `naro_araneae_page009.html` | 9 | HTML | `https://insect-web.rad.naro.go.jp/search/basic?category=BB00006378&...&page=N` |

`fetch_data.pl` は page=1 を取得して総件数（`... 件`）を読み、`ceil(件数 / 30)` ページ分を巡回する。

## 手動で配置するファイル

なし。

## 補足

- README に記載の `https://insect-web.rad.naro.go.jp/flame/tree` はフレームセットでデータを含まない。実データは `search/basic`。
- 門/綱/目/科/属/種の列に配置されるので **rank が明示的に得られ**、セル内の `└` 記号が中間階層を表して **subrank に対応する**。
- 和名に表記揺れがある（和名欄に学名、全角スペース混入、末尾の余分なスペース）。
- robots.txt は `Disallow:`（空）で全面許可。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
