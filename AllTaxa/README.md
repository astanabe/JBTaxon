# 全体 (AllTaxa)

全生物種を対象とする情報源を置くディレクトリ。国土技術政策総合研究所「河川水辺の国勢調査のための生物リスト」、GBIF Backbone Taxonomy、Wikidata の3つを使用する。

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

### GBIF Backbone Taxonomy

| ファイル | 形式 | 情報源 |
|---|---|---|
| `backbone.zip` | Darwin Core Archive (zip) | `https://hosted-datasets.gbif.org/datasets/backbone/2023-08-28/backbone.zip` |

DOI は https://doi.org/10.15468/39omei 。**約927MB あるので取得に時間がかかる。**`generate_tables.pl` が自動的に展開し、展開後の `Taxon.tsv` (約2.2GB) と `VernacularName.tsv` を使う。

### Wikidata

| ファイル | 形式 | 情報源 |
|---|---|---|
| `wikidata.csv` | CSV | `https://qlever.dev/api/wikidata` に `wikidata.rq` を POST した結果 |

`wikidata.rq` は SPARQL クエリで、**唯一リポジトリで追跡している分類群ディレクトリ内のファイル**である (`.gitignore` で再包含している)。WDQS (query.wikidata.org) では60秒制限により完走しないため QLever を使う。

## 手動で配置するファイル

なし。

## 補足

- **令和元年度 (R01) 以降の「全生物種」のみを使用する。** 平成年度のものは `.lzh` 書庫で提供されているが対象外なので、LZH 展開は実装しない。
- GBIF の和名は `VernacularName.tsv` の `language` が `ja` の行にある (27,558件)。うち約6,800件は「Tenjikuzame」のようなローマ字表記で、和名ではないので出力しない。
- GBIF の版は URL に固定してある (2023-08-28)。新しい版に上げるときは `fetch_data.pl` 自体を更新する。
- 一覧ページ自体の文字コードは cp932。
- robots.txt に `/lab/fbg/` を対象とする Disallow はなく、ページに利用条件の記載もない。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
