# NCBI Taxonomy (NCBITaxonomy)

**このディレクトリは種名チェックリストではない。** 1つの和名に複数の学名が併記されている行について、どちらが有効名かを判定するための参照データを置く。

`generate_tables.pl` は有効名を次の順で決める。

1. Catalogue of Life (`AllTaxa/NameUsage.tsv`) の `col:status`
2. NCBI Taxonomy (`NCBITaxonomy/names.dmp`) の name class（`scientific name` なら有効名）
3. どちらでも決められなければ、実行の最後に「注意」として報告する

Catalogue of Life は WoRMS をはじめ多数のデータベースを統合しているので、この2段で足りる。

## 自動ダウンロードされるファイル

| ファイル | 形式 | 情報源 |
|---|---|---|
| `taxdump.tar.gz` | tar.gz | `https://ftp.ncbi.nih.gov/pub/taxonomy/taxdump.tar.gz` |

`fetch_data.pl` が取得した直後に `tar` で展開し、`names.dmp` や `nodes.dmp` などを同じディレクトリに置く。**書庫の展開を `fetch_data.pl` が行うのはここだけ**である（手動配置分の zip は `fetch_data.pl` の実行後に置かれるため `generate_tables.pl` の仕事だが、これは自分でダウンロードした書庫なので取得直後に展開してよい）。

展開済み（`names.dmp` が存在する）ならスキップし、`--force` で展開し直す。

## 手動で配置するファイル

なし。

## 補足

- `names.dmp` は `taxid | 名前 | ユニーク名 | name class |` のタブ+パイプ区切り。約313MB・510万行。
- **版は固定していない。** 他の情報源と違い `taxdump.tar.gz` は常に最新版を指す URL しかなく、内容も分類体系の更新に追随するだけでフォーマットは安定しているため。
- 公開ドメイン（NCBI のデータは著作権による制限を受けない）。

## 注意

このディレクトリ内のデータファイルは**リポジトリにコミットしないこと**。
