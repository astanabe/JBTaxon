# クモ類 (Spiders)

NARO 昆虫インベントリーデータベースの Araneae (category=`BB00006378`, 255件) と、塩崎 哲哉「クモ図鑑」(https://araneae.web.fc2.com/kumozukan/) を使用する。

## 自動ダウンロードされるファイル

| ファイル | 数 | 形式 | 情報源 |
|---|---:|---|---|
| `naro_araneae_page001.html` 〜 `naro_araneae_page009.html` | 9 | HTML | `https://insect-web.rad.naro.go.jp/search/basic?category=BB00006378&...&page=N` |
| `kumozukan/index_Japanesename.html` | 1 | HTML (cp932) | `https://araneae.web.fc2.com/kumozukan/index_Japanesename.html` |
| `kumozukan/<名前>.html` | 548 | HTML (UTF-8) | `https://araneae.web.fc2.com/kumozukan/<名前>/<名前>.html` |

- NARO: `fetch_data.pl` は page=1 を取得して総件数（`... 件`）を読み、`ceil(件数 / 30)` ページ分を巡回する。
- クモ図鑑: `fetch_data.pl` は和名索引を取得し、HTML コメントを落としてから種のページへのリンクを拾って巡回する（5秒間隔で約46分）。コメントの中には未公開のページへのリンクが20件ある。索引からのリンクのうち `naranukagumo` は情報源側のリンク切れ（302 で FC2 のエラーページへ転送される）で、取得は常に1件失敗する。

## 手動で配置するファイル

なし。

## 補足

- NARO
  - README に記載の `https://insect-web.rad.naro.go.jp/flame/tree` はフレームセットでデータを含まない。実データは `search/basic`。
  - 門/綱/目/科/属/種の列に配置されるので **rank が明示的に得られ**、セル内の `└` 記号が中間階層を表して **subrank に対応する**。
  - 和名に表記揺れがある（和名欄に学名、全角スペース混入、末尾の余分なスペース）。
  - 「お知らせ」の最新が「2018/01/10 公開再開しました。」なので、内容は 2018 年版とみなす（`sources.tsv` の `year` は 2018）。
  - robots.txt は `Disallow:`（空）で全面許可。
- クモ図鑑
  - 和名索引から種の和名・学名と科の和名・学名が、種のページから属の和名・学名が取れる。種544・属265・科49。
  - 索引と種のページが食い違うときは種のページを採る。種のページの欄が空のときと、種のページが無いときだけ索引で補う。
  - 科と属は種のページごとに書かれていて綴りの誤りが混ざるので、和名ごとに最も多くのページに書かれている学名を採る。
  - 版はトップページの `Ver20250802`（`year` は 2025）。分類は谷川明男「日本産クモ類目録」に準拠している。
  - robots.txt は存在しない。サイトに転載や利用を制限する記載はない（`Copyright (c) 2024 Tetsuya SHIOZAKI. All Rights Reserved.` のみ）。
- 2ソースは scope が同じ（クモ目、14）なので、同じ組の出典は新しいクモ図鑑になる。NARO にしかない名前（古い属の和名や旧称）は NARO の判定で残る。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
