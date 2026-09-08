# 全体 (AllTaxa)

全生物種を対象とする情報源を置くディレクトリ。国土技術政策総合研究所「河川水辺の国勢調査のための生物リスト」、Catalogue of Life、Wikidata の3つを使用する。

## 自動ダウンロードされるファイル

### 河川水辺の国勢調査のための生物リスト

`fetch_data.pl` を実行すると以下の7ファイルが取得される。

| ファイル | 形式 | 情報源 |
|---|---|---|
| `R01zenseibutsu.xlsx` | Excel | `https://www.nilim.go.jp/lab/fbg/ksnkankyo/mizukokuweb/system/DownLoad/List/R01List/R01zenseibutsu.xlsx` |
| `R02zenseibutsu.xlsx` | Excel | 同上 (`R02List/R02zenseibutsu.xlsx`) |
| `R03zenseibutsu.xlsx` | Excel | 同上 (`R03List/R03zenseibutsu.xlsx`) |
| `R04zenseibutsu.xlsx` | Excel | 同上 (`R04List/R04zenseibutsu.xlsx`) |
| `R05zenseibutsu.xlsx` | Excel | 同上 (`R05List/R05zenseibutsu.xlsx`) |
| `R06zenseibutsu.xlsx` | Excel | 同上 (`R06List/R06zenseibutsu.xlsx`) |
| `R07zenseibutsu.xlsx` | Excel | 同上 (`R07List/R07zenseibutsu.xlsx`) |

一覧ページは https://www.nilim.go.jp/lab/fbg/ksnkankyo/mizukokuweb/system/seibutsuListfile.htm 。

### Catalogue of Life

| ファイル | 形式 | 情報源 |
|---|---|---|
| `2026-08-26_xr_coldp.zip` | ColDP (zip) | `https://download.checklistbank.org/col/monthly/2026-08-26_xr_coldp.zip` |

2026-08-26 XR (Extended Release)。**約1.26GB あるので取得に時間がかかる。**書庫は展開すると 5.6GB・21,425 ファイルになるため、`generate_tables.pl` は**使う2ファイル (`NameUsage.tsv` 約3GB と `VernacularName.tsv`) だけを展開する**。提供元のメタデータ (`source/<ID>.yaml`) は展開せず書庫から直接読む。

### Wikidata

| ファイル | 形式 | 情報源 |
|---|---|---|
| `wikidata.csv` | CSV | `https://qlever.dev/api/wikidata` に `wikidata.rq` を POST した結果 |

`wikidata.rq` は SPARQL クエリで、**唯一リポジトリで追跡している分類群ディレクトリ内のファイル**である (`.gitignore` で再包含している)。WDQS (query.wikidata.org) では60秒制限により完走しないため QLever を使う。

## 手動で配置するファイル

なし。

## 補足

- **令和元年度 (R01) 以降の「全生物種」のみを使用する。** 平成年度のものは `.lzh` 書庫で提供されているが対象外なので、LZH 展開は実装しない。
- Catalogue of Life の和名は `VernacularName.tsv` の `language` が `jpn` の行にある (99,738件)。**GBIF Backbone Taxonomy (27,558件) の上位互換**で、WoRMS・FishBase・ITIS など多数のデータベースを統合している。
- **エントリごとに `sourceID` (提供元データセット) を持つ。** README の規定により、その提供元のタイトル・著者・URL を出典として出力する。`source/<ID>.yaml` から `title` / `author`→`editor`→`creator`→`contact` / `url` を読む。人名が書かれていないデータベース (FishBase など) は団体名、それも無ければ表題を著者に使う。
- CoL の版は URL に固定してある (`col/monthly/2026-08-26_xr_coldp.zip`)。新しい版に上げるときは `fetch_data.pl` 自体を更新する。
- `download.checklistbank.org` に robots.txt はない (HTTP 404)。ChecklistBank の API 側 (`api.checklistbank.org`) は `User-agent: * / Disallow: /` なので、月次の配布ファイルを置いている `download.checklistbank.org` を使う。
- 一覧ページ自体の文字コードは cp932。
- robots.txt に `/lab/fbg/` を対象とする Disallow はなく、ページに利用条件の記載もない。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
