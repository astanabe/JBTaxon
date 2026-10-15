# 昆虫 (Insects)

昆虫の情報源は数が多く、**サブディレクトリを作らずこのディレクトリ直下にフラットに配置する**。そのため `generate_tables.pl` はファイル名でソースを判別する。**下表のファイル名はソース識別子を兼ねる契約**なので、安易に変更しないこと。

## 自動ダウンロードされるファイル

| ファイル | 数 | 形式 | 情報源 |
|---|---:|---|---|
| `naro_insecta_page001.html` 〜 `naro_insecta_page365.html` | 365 | HTML | NARO 昆虫インベントリーDB `search/basic` (category=`BB00000004`) |
| `ListMJ3-210603DL.xlsx` | 1 | Excel | List-MJ 日本産蛾類総目録 `http://listmj.mothprog.com/dl/ListMJ3-210603DL.xlsx` |
| `staphylinidae_p069.pdf` | 1 | PDF | 日本産ハネカクシ科総目録 (九州大学リポジトリ `opac_download_md/26400/p069.pdf`) |
| `aculeata_hym_list_2016_ver5.pdf` | 1 | PDF | 日本産有剣膜翅類目録 2016年版 (Web Archive) |
| `shigainsect_Thysanoptera.tsv` ほか27件 | 28 | TSV | 滋賀県昆虫目録2025 の目別スプレッドシート https://sites.google.com/view/shigainsect/ |
| `trichoptera_checklist.tsv` | 1 | TSV | 日本産トビケラの種名一覧 https://sites.google.com/view/tobikera/home/checklist |
| `butterfly_Hesperiidae.html` ほか4件 | 5 | HTML | 日本産蝶類の学名リスト 科別ページ https://japanesebutterfly.wixsite.com/butterfly-list |

計 434 ファイル。

### NARO 昆虫DB について

- README に記載の `https://insect-web.rad.naro.go.jp/flame/tree` は 809 バイトのフレームセットでデータを含まない。実データは `search/basic`（30件/ページ）と `search/tree.json` の2系統がある。
- **`fetch_data.pl` は `search/basic` のみを使用する**（計 10,931 件 → 365ページ）。門/綱/目/科/属/種の列に配置されるので **rank が明示的に得られ**、セル内の `└` 記号が中間階層（上科・亜綱など）を表して **subrank にそのまま対応する**。`tree.json` 巡回は約4,700リクエスト必要で採らない。
- 和名に表記揺れがある（和名欄に学名が入る `Setodes (Setodes属)`、全角スペース混入 `Eubasilissa (ムラサキトビケラ 属)`、末尾の余分なスペース）。
- NARO のトビケラ目は14ノードしかなく、専用ソース (`trichoptera_checklist.tsv`) の方が遥かに充実している。「より狭い分類群のソースを優先」が効く場面。

### 日本産蝶類の学名リスト について

科ごとに1ページ、計5ページ（セセリチョウ科・アゲハチョウ科・シロチョウ科・シジミチョウ科・タテハチョウ科）。ページ名が日本語なので `fetch_data.pl` はパーセントエンコードした URL を持ち、`butterfly_<科の学名>.html` として保存する。

Wix のサイトだが本文はサーバ側で描画されているので HTML から読める。1レコードが1つの `<p class="font_N">` で、**学名だけが `font-style:italic` の span に入っている**。

```
Family Hesperiidae セセリチョウ科
Subfamily Coeliadinae アオバセセリ亜科
Tribe Zerynthiini タイスアゲハ族
Genus <i>Luehdorfia</i> Cruger, 1878 ギフチョウ属
<i>Luehdorfia japonica</i> Leech, 1889 ギフチョウ Japanese luehdorfia
ssp. <i>yessoensis</i> Rothschild, 1918 北海道亜種
```

- **亜種の行は種小名しか書かれていない**ので直前の種の学名に連結し、和名も直前の種の和名に修飾語を付けて組み立てる（「ヒメギフチョウ 北海道亜種」）。修飾語がない亜種は種の和名をそのまま使う。
- 種の行の「`Papilio (Menelaides) polytes`」のような**亜属名は二名法の学名からは外す**（他の情報源と照合できなくなるため）。
- **「`Genue Troides`」のように綴りを誤った見出しがある**ので、キーワードで決まらないときは和名の接尾辞でも rank を判定する。
- 和名のない見出し（`Tribe Astictopterini`、`Subgenus Menelaides` など）は出力に寄与しない。
- 旧情報源は「日本産蝶類和名学名便覧」（Web Archive 経由、CC BY 3.0）だったが、2026年に新サイトが公開されたので差し替えた。

### Google スプレッドシートの TSV 書き出し について

shigainsect とトビケラは Google スプレッドシートで公開されており、`https://docs.google.com/spreadsheets/d/<ID>/export?format=tsv` で TSV として取得する。`docs.google.com` の robots.txt は `Allow: /spreadsheet` で `/spreadsheets/d/<ID>/export` を許可している（2026-10-15 確認）。

- 書き出されるのは**先頭のシートだけ**。どちらも先頭のシートが本体である。
- 引用符は使われず、結合セルとセル内の改行は無い。
- shigainsect の目とスプレッドシートの ID の対応は、トップページのリンクから取って `fetch_data.pl` に固定してある。ファイル名の英名も日本語の目名に合わせて固定したもので、シートの `Order` 列の値（揺れがある）は使わない。文献表（「こちら」）と一括ダウンロードの ZIP は取得しない。
- ガロアムシ目（`shigainsect_Notoptera.tsv`）だけ、見出しの `種名（学名）` と `種名（和名）` が入れ替わっている（データの並びは他と同じ）。

### トビケラ について

- 日本トビケラ情報ネットワーク「日本産トビケラの種名一覧」。Google Sites のページに埋め込まれたスプレッドシートを読む。旧情報源は野崎「日本産トビケラの種リスト」(`tobikera.eco.coocan.jp/names.htm`) だった。
- 空の列による字下げが階層を表す（1列目=亜目、2列目=科、3列目=属、4列目=種の学名、5列目=種の和名）。4列目が `種名` の行は見出し。
- **属名が頭文字省略形**（`C. aira`）で書かれており、直前の属名行を保持して展開する必要がある。

## 手動で配置するファイル

なし。

## 補足

- List-MJ と FernGreenList は CC0。
- List-MJ の robots.txt は HTTP 500 を返す。RFC 9309 の厳密な解釈では 5xx は全面 disallow だが、サイト本体は正常稼働し、データは CC0、`about.html` に明示的なダウンロードリンクがある。実質は robots.txt 未設置のサーバエラーと見られる。
- ハネカクシの九大リポジトリは `Disallow: /` だが `Allow: /opac_download_md/` があり、取得先は明示的に許可されている。

## 注意

このディレクトリ内の生データファイルは**リポジトリにコミットしないこと**。情報源の一部は改変・再配布が禁止されており、JBTaxon が配布するのは生成用スクリプトだけである。
