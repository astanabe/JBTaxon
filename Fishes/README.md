# 魚類 (Fishes)

鹿児島大学総合研究博物館「日本産魚類全種目録 (JAF List)」を使用する。

## 自動ダウンロードされるファイル

| ファイル | 形式 | 情報源 |
|---|---|---|
| `20260827_JAFList.xlsx` | Excel | `https://www.museum.kagoshima-u.ac.jp/staff/motomura/20260827_JAFList.xlsx` |

案内ページは https://www.museum.kagoshima-u.ac.jp/staff/motomura/jaf.html 。

## 手動で配置するファイル

なし。

## 補足

- **ファイル名に日付が入り版が切られるが、`fetch_data.pl` は URL をハードコードしている。** 新しい版が出たときは `fetch_data.pl` 自体を更新して対応する（版が変わると Excel のフォーマット自体が変化している可能性があり、ダウンロードだけ自動追従すると `generate_tables.pl` が壊れるため）。
- robots.txt は設置されていない。「利用は自由ですが，できればご一報ください」との記載と引用要請がある。**出典明記が求められる情報源**。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
