# 線形動物 (Nematodes)

NARO 昆虫インベントリーデータベースの Nematoda (category=`BB00011689`, 633件) を使用する。

## 自動ダウンロードされるファイル

| ファイル | 数 | 形式 | 情報源 |
|---|---:|---|---|
| `naro_nematoda_page001.html` 〜 `naro_nematoda_page022.html` | 22 | HTML | `https://insect-web.rad.naro.go.jp/search/basic?category=BB00011689&...&page=N` |

`fetch_data.pl` は page=1 を取得して総件数（`... 件`）を読み、`ceil(件数 / 30)` ページ分を巡回する。中断後の再開時は page=1 がスキップされるので、総件数はディスク上の page=1 ファイルから読み直される。

## 手動で配置するファイル

なし。

## 補足

- README に記載の `https://insect-web.rad.naro.go.jp/flame/tree` はフレームセットでデータを含まない。実データは `search/basic`。
- 門/綱/目/科/属/種の列に配置されるので **rank が明示的に得られ**、セル内の `└` 記号が中間階層（上科・亜綱など）を表して **subrank に対応する**。例: 目の列の `Ascaridida(回虫目) └ Seuratoidea` は上科、綱の列の `└ Chromadoria (クロマドラ亜綱)` は亜綱。
- robots.txt は `Disallow:`（空）で全面許可。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
