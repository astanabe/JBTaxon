# WoRMS (World Register of Marine Species)

**このディレクトリは種名チェックリストではない。** また `fetch_data.pl` の対象でもない。1つの和名に複数の学名が併記されている行について、GBIF Backbone Taxonomy と NCBI Taxonomy のどちらでも有効名を決められなかったときに `generate_tables.pl` が WoRMS の REST API へ問い合わせ、その結果をここに貯める。

`generate_tables.pl` は有効名を次の順で決める。

1. GBIF Backbone Taxonomy (`AllTaxa/Taxon.tsv`) の `taxonomicStatus`
2. NCBI Taxonomy (`NCBITaxonomy/names.dmp`) の name class
3. **WoRMS** (`https://www.marinespecies.org/rest/AphiaRecordsByName/<学名>`) の `status` と `valid_name`
4. どれでも決められなければ、実行の最後に「注意」として報告する

## 生成されるファイル

| ファイル | 内容 |
|---|---|
| `cache.tsv` | `学名 <TAB> status <TAB> valid_name` の問い合わせ結果。次回以降は再問い合わせしない |

## 補足

- **`generate_tables.pl` が唯一ネットワークにアクセスするのがこの経路**である。上の2段で決まった名前は問い合わせないので、通常の実行で発生する問い合わせは0〜数件にとどまる。
- 問い合わせと問い合わせの間は5秒空ける。`marinespecies.org` の robots.txt は `Crawl-delay: 1` と `/structure` `/export` の Disallow のみで、`/rest/` は対象外。
- **通信できない場合は判定を諦めるだけで処理は止まらない。** オフラインでも `generate_tables.pl` は完走する（決められなかった旨が「注意」に出る）。
- スコアは `3` = `accepted` / `2` = 有効名と属名が一致する（現在の組み合わせ）/ `1` = 登録はあるがそのどちらでもない / `0` = 見つからない。
  例えば「ヤマドリ」の `Synchiropus ijimai` と `Neosynchiropus ijimai` はどちらも `unaccepted` だが、WoRMS の有効名が `Neosynchiropus ijimae` なので属名の一致する後者が採用される。
- `cache.tsv` を消せば次回の実行で問い合わせ直す。

## 注意

このディレクトリ内のファイルは**リポジトリにコミットしないこと**。
