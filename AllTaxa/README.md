# 全体 (AllTaxa)

全生物種を対象とする情報源を置くディレクトリ。国土技術政策総合研究所「河川水辺の国勢調査」の生物リストを使用する。

## 自動ダウンロードされるファイル

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

## 手動で配置するファイル

なし。

## 補足

- **令和元年度 (R01) 以降の「全生物種」のみを使用する。** 平成年度のものは `.lzh` 書庫で提供されているが対象外なので、LZH 展開は実装しない。
- 一覧ページ自体の文字コードは cp932。
- robots.txt に `/lab/fbg/` を対象とする Disallow はなく、ページに利用条件の記載もない。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
