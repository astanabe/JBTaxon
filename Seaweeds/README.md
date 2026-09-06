# 海藻 (Seaweeds)

日本産海藻リストを使用する。HTML ページ自体がデータファイル。

## 自動ダウンロードされるファイル

トップページ https://tonysharks.com/Seaweeds_list/Seaweed_list_top.html は更新履歴のポータルで、実データは分類群別ページに分散している。`fetch_data.pl` はトップページから `Brown/`・`Red/`・`Green/`・`Numbers/` 配下の `.html` へのリンクを抽出し（`#fragment` は除去して重複排除）、**相対パスを保ったまま**保存する。

| ファイル | 数 | 形式 |
|---|---:|---|
| `Seaweed_list_top.html` | 1 | HTML |
| `Brown/*.html`（褐藻） | 22 | HTML |
| `Red/*.html`（紅藻） | 25 | HTML |
| `Green/*.html`（緑藻） | 7 | HTML |
| `Numbers/numbers.html` | 1 | HTML |

## 手動で配置するファイル

なし。

## 補足

- **`Red/Erythropeltidales.html` は情報源側のリンク切れ。** トップページから2箇所リンクされているがサーバ上に実体がなく HTTP 404 を返すため取得できない。`fetch_data.pl` はこれを失敗として報告し、終了コード 1 で終わる（他のファイルは全て取得される）。リンク抽出は 26 件だが取得できるのは 25 件。
- トップページには `href="Brown/Ochrophyta#Xanthophyceae.html"` のようにフラグメントが拡張子の前に来る壊れたリンクが混じっている。`fetch_data.pl` はこれらを取得対象から除外するが、正しいリンク (`Brown/Ochrophyta.html`) が別途あるのでページの取りこぼしはない。
- robots.txt に制限はなく、利用条件の記載もない。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
