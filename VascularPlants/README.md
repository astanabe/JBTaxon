# 維管束植物 (VascularPlants)

YList（植物和名-学名インデックス）と FernGreenList（日本産シダ植物チェックリスト）を使用する。

## 自動ダウンロードされるファイル

| ファイル | 形式 | 情報源 |
|---|---|---|
| `20210514YList_download.xlsx` | Excel | `http://ylist.info/20210514YList_download.xlsx` |
| `FernGreenListV2.0.csv` | CSV (UTF-8) | `https://ndownloader.figshare.com/files/41467776` |

YList の案内ページは http://ylist.info/ 、FernGreenList は https://doi.org/10.57400/data.bnmnsbot.22696618 。

## 手動で配置するファイル

なし。

## 補足

- **YList は Excel 版が正本。** 同じ内容のタブ区切りテキスト (`20210514YList_download_tab.txt`) も配布されているが**使用しない**。
- YList の robots.txt は未設置。「右クリックで保存してお使い下さい」と明示されており、引用形式の指定がある。**出典明記が求められる情報源**。
- FernGreenList は **CC0**。CSV は `Japanese name 和名` と `Synonym of Japanese name 和名異名` の列を持ち、**和名シノニムをそのまま利用できる**。
- figshare は DOI 解決後の実 URL (`ndownloader.figshare.com/files/41467776`) を直接指定している。DOI 解決や figshare API 呼び出しは行わない。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
